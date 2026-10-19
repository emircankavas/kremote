import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A byte pipe to a live SFTP subsystem.
///
/// Deliberately tiny and injectable: this is the only part that needs a real
/// process, so the client and codec above it are unit-testable without a server.
public protocol SFTPTransport: AnyObject, Sendable {
    /// Starts the subsystem and completes once it is running. Throws when the
    /// process could not be spawned at all.
    func open() async throws
    /// Writes all of `data` (blocking until the kernel accepts it).
    func write(_ data: Data) throws
    /// Reads whatever is available, blocking until at least one byte arrives or
    /// the pipe reaches EOF (which returns `nil`).
    func read(maxLength: Int) throws -> Data?
    /// Any text the child wrote to stderr — ssh's own diagnostics, or the
    /// server's complaint. Used to explain a failed connection.
    func stderrText() -> String
    /// Terminates the child and closes the pipes. Idempotent.
    func close()
    /// True while the child is alive.
    var isAlive: Bool { get }
}

/// Runs `ssh -T <target> -s sftp` on plain pipes.
///
/// No PTY: SFTP is a binary protocol and a terminal would mangle it (CR/LF
/// translation, echo). `-T` makes ssh not request one; stdin/stdout then carry
/// the protocol untouched and stderr carries the diagnostics separately.
///
/// Read on one thread and write on another — the same rule as `SSHPtySession`.
/// A blocking `read()` on the writing queue would starve every request.
public final class ProcessSFTPTransport: SFTPTransport, @unchecked Sendable {
    private let arguments: [String]
    /// Extra environment for the child (askpass variables live here).
    private var environment: [String: String]
    /// Password typed by ssh through our own askpass helper. Never appears in
    /// argv — argv is world-readable through `ps`.
    private let password: String
    /// Temporary askpass script, removed on close.
    private var askpassURL: URL?

    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()

    private let stateLock = NSLock()
    private var _closed = false
    private var _stderr = Data()

    /// Guards the buffers below, which are filled on a background queue.
    private let bufferLock = NSLock()
    private var readBuffer = Data()

    public init(
        arguments: [String],
        environment: [String: String] = [:],
        password: String = ""
    ) {
        self.arguments = arguments
        self.environment = environment
        self.password = password
    }

    /// Builds the argv-style command from a connection's resolved settings.
    ///
    /// The same `ssh` options as the terminal path are used, so `~/.ssh/config`,
    /// keys, the agent and ProxyJump behave identically — but with `-T` and the
    /// subsystem instead of an interactive shell.
    ///
    /// `password` is typed by ssh through a generated `SSH_ASKPASS` helper.
    /// There is no TTY on this connection (a terminal would corrupt the binary
    /// protocol), so without askpass ssh has nowhere to read a password from and
    /// dies with "ssh_askpass: exec(...): No such file or directory".
    public convenience init(
        host: String,
        port: Int,
        username: String,
        identityFile: String,
        password: String = "",
        remoteCommand: String = "",
        extraOptions: [String] = []
    ) {
        var args = ["-T"]
        args += ["-o", "NumberOfPasswordPrompts=2"]
        args += ["-o", "PreferredAuthentications=publickey,password,keyboard-interactive,gssapi-with-mic"]
        args += ["-o", "StrictHostKeyChecking=accept-new"]
        // Timeouts are ssh's job, not the caller's: a blocked pipe read cannot be
        // interrupted from Swift, so a black-holed host would hang the caller
        // forever. `ConnectTimeout` bounds the TCP/handshake wait;
        // `ServerAlive*` kills a live connection that stops answering.
        args += ["-o", "ConnectTimeout=20"]
        args += ["-o", "ServerAliveInterval=30"]
        args += ["-o", "ServerAliveCountMax=3"]
        args += extraOptions
        if port > 0, port != 22 { args += ["-p", String(port)] }
        let key = identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { args += ["-i", (key as NSString).expandingTildeInPath] }
        let target = username.isEmpty ? host : "\(username)@\(host)"
        args.append(target)

        // A remote command replaces the subsystem: this is the elevation path
        // (`sudo -S -p '' <sftp-server>`), where ssh must not open the
        // subsystem itself.
        let command = remoteCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if command.isEmpty {
            args.append("-s")
            args.append("sftp")
        } else {
            args.append(command)
        }
        self.init(arguments: args, password: password)
    }

    /// The full argv this transport will run, for logging/tests.
    public var commandLine: [String] { ["ssh"] + arguments }

    // MARK: - Lifecycle

    public func open() async throws {
        process.executableURL = URL(fileURLWithPath: Self.sshPath)
        process.arguments = arguments
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // A clean environment: no inherited locale surprises that could make the
        // server quote its error text differently. The user's own env is kept.
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment { env[key] = value }

        // ssh has no terminal here, so a password can only come from askpass.
        // Without this, ssh tries /usr/X11R6/bin/ssh-askpass (absent on macOS)
        // and the connection dies before the protocol even starts.
        if !password.isEmpty {
            do {
                let helper = try Self.makeAskpassHelper(password: password)
                askpassURL = helper
                env["SSH_ASKPASS"] = helper.path
                env["SSH_ASKPASS_REQUIRE"] = "force"
                // ssh refuses askpass without a DISPLAY on some builds; the value
                // is never used by the helper, it only satisfies the check.
                env["DISPLAY"] = env["DISPLAY"] ?? ":0"
            } catch {
                throw SFTPError.transport("could not prepare the password helper: \(error.localizedDescription)")
            }
        }
        process.environment = env

        do {
            try process.run()
        } catch {
            removeAskpassHelper()
            throw SFTPError.transport("could not start ssh: \(error.localizedDescription)")
        }

        // Drain stderr on its own queue so the child can never block writing to
        // it (a stuck stderr pipe is a classic deadlock).
        let errorHandle = errorPipe.fileHandleForReading
        let lock = self.bufferLock
        errorHandle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let self else { return }
            lock.withLock { self.stderrBuffer.append(chunk) }
        }

        // Wait very briefly for an immediate failure (bad key, unreachable host)
        // so the caller gets ssh's reason instead of a protocol timeout.
        let deadline = Date().addingTimeInterval(0.15)
        while Date() < deadline, process.isRunning {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if !process.isRunning, process.terminationStatus != 0 {
            let reason = stderrText().trimmingCharacters(in: .whitespacesAndNewlines)
            throw SFTPError.transport(reason.isEmpty ? "ssh exited with status \(process.terminationStatus)" : reason)
        }
    }

    public var isAlive: Bool {
        stateLock.withLock { !_closed } && process.isRunning
    }

    public func close() {
        let alreadyClosed = stateLock.withLock { () -> Bool in
            if _closed { return true }
            _closed = true
            return false
        }
        guard !alreadyClosed else { return }
        errorPipe.fileHandleForReading.readabilityHandler = nil
        try? inputPipe.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        outputPipe.fileHandleForReading.closeFile()
        errorPipe.fileHandleForReading.closeFile()
        removeAskpassHelper()
    }

    // MARK: - Askpass helper

    /// Writes a tiny script that prints the password on stdout, which is exactly
    /// what ssh expects from `SSH_ASKPASS`.
    ///
    /// The password lives in a 0700 directory with a 0700 file and is removed when
    /// the session closes — never in argv, and never in the environment where a
    /// sibling process could read it out of `/proc`-equivalent listings.
    static func makeAskpassHelper(password: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kremote-askpass-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let script = directory.appendingPathComponent("askpass.sh")

        // The password is passed as a base64 argument so quotes, newlines and
        // backslashes in it cannot break the script or the shell.
        let encoded = Data(password.utf8).base64EncodedString()
        let body = """
        #!/bin/sh
        # KRemote's SSH_ASKPASS helper: print the stored password and nothing else.
        printf '%s' '\(encoded)' | /usr/bin/base64 -D
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }

    private func removeAskpassHelper() {
        guard let askpassURL else { return }
        let directory = askpassURL.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: directory)
        self.askpassURL = nil
    }

    // MARK: - IO

    public func write(_ data: Data) throws {
        guard isAlive else { throw SFTPError.connectionClosed(stderrText()) }
        let handle = inputPipe.fileHandleForWriting
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw SFTPError.connectionClosed(error.localizedDescription)
        }
    }

    public func read(maxLength: Int) throws -> Data? {
        // Serve anything already buffered first.
        let buffered = bufferLock.withLock { () -> Data? in
            guard !readBuffer.isEmpty else { return nil }
            let chunk = readBuffer.prefix(maxLength)
            readBuffer.removeFirst(chunk.count)
            return Data(chunk)
        }
        if let buffered { return buffered }

        let handle = outputPipe.fileHandleForReading
        let chunk: Data
        do {
            chunk = handle.availableData
        } catch {
            throw SFTPError.connectionClosed(error.localizedDescription)
        }
        if chunk.isEmpty { return nil }   // EOF: the child closed stdout.
        return chunk
    }

    private var stderrBuffer = Data()

    public func stderrText() -> String {
        let text = bufferLock.withLock { String(decoding: stderrBuffer, as: UTF8.self) }
        return Self.cleanDiagnostics(text)
    }

    /// Strips the lines ssh prints on every successful contact ("Warning:
    /// Permanently added … to the list of known hosts") so an error message shows
    /// the reason and not the boilerplate above it.
    static func cleanDiagnostics(_ text: String) -> String {
        let noise = ["warning: permanently added", "warning: added the"]
        let kept = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                let lower = line.lowercased()
                return !lower.isEmpty && !noise.contains(where: { lower.hasPrefix($0) })
            }
        return kept.joined(separator: "\n")
    }

    public static var sshPath: String {
        for candidate in ["/usr/bin/ssh", "/usr/local/bin/ssh", "/opt/homebrew/bin/ssh"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return "/usr/bin/ssh"
    }
}
