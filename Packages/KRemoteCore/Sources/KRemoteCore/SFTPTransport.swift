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
    /// Extra arguments placed before the destination (e.g. `-p 2222`).
    private let environment: [String: String]

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

    public init(arguments: [String], environment: [String: String] = [:]) {
        self.arguments = arguments
        self.environment = environment
    }

    /// Builds the argv-style command from a connection's resolved settings.
    ///
    /// The same `ssh` options as the terminal path are used, so `~/.ssh/config`,
    /// keys, the agent and ProxyJump behave identically — but with `-T` and the
    /// subsystem instead of an interactive shell.
    public convenience init(
        host: String,
        port: Int,
        username: String,
        identityFile: String,
        remoteCommand: String = "",
        extraOptions: [String] = []
    ) {
        var args = ["-T"]
        args += ["-o", "NumberOfPasswordPrompts=1"]
        args += ["-o", "PreferredAuthentications=publickey,password,keyboard-interactive,gssapi-with-mic"]
        args += ["-o", "StrictHostKeyChecking=accept-new"]
        // Timeouts are ssh's job, not the caller's: a blocked pipe read cannot be
        // interrupted from Swift, so a black-holed host would hang the caller
        // forever. `ConnectTimeout` bounds the TCP/handshake wait;
        // `ServerAlive*` kills a live connection that stops answering.
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
        self.init(arguments: args)
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
        process.environment = env

        do {
            try process.run()
        } catch {
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
        return text
    }

    public static var sshPath: String {
        for candidate in ["/usr/bin/ssh", "/usr/local/bin/ssh", "/opt/homebrew/bin/ssh"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return "/usr/bin/ssh"
    }
}
