import Foundation

/// Runs a command on the server over the connection's own `ssh`, with its output
/// streamed back.
///
/// SFTP v3 cannot ask the server to run a program, and archiving on the server is
/// worth a second connection: a `.tar.gz` is transferred instead of the
/// uncompressed files, and no temporary copy is written to this Mac's disk.
///
/// This is deliberately a separate channel rather than a method on `SFTPClient`:
/// the subsystem and a shell command are two different connections on the same
/// server, and mixing them would make the SFTP request ids ambiguous.
public final class RemoteShell: @unchecked Sendable {
    public struct Output: Sendable {
        public let stdout: Data
        public let stderr: String
    }

    private let host: String
    private let port: Int
    private let username: String
    private let identityFile: String
    private let password: String
    /// When set, `runElevated` can start a privileged channel.
    private let elevation: ElevationProvider?
    /// When set, every command rides one authenticated connection instead of
    /// authenticating again. Used by the metrics sampler, which runs every 5s.
    private let controlPath: String?

    public init(
        host: String,
        port: Int,
        username: String,
        identityFile: String,
        password: String,
        elevation: ElevationProvider? = nil,
        controlPath: String? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.identityFile = identityFile
        self.password = password
        self.elevation = elevation
        self.controlPath = controlPath
    }

    /// Streams the command's stdout to `consume` as it arrives.
    ///
    /// The command is wrapped in `/bin/sh -c` on the server with every path
    /// quoted by `ShellQuote`, so a filename is always a filename.
    public func run(
        _ command: String,
        timeout: TimeInterval = 300,
        consume: (@Sendable (Data) -> Void)? = nil
    ) async throws -> Output {
        try await stream(command, elevated: false, timeout: timeout, consume: consume)
    }

    /// Streams the same command **as root**.
    ///
    /// Elevation reuses `ElevationProvider` instead of re-implementing the sudo
    /// handshake: that code already writes the password as one stdin line, refuses
    /// a password containing a newline, and turns sudo's own complaint into one
    /// typed error. `ElevationCommand.remoteCommand` starts the *subsystem* as
    /// root for the SFTP path; here the elevated channel runs the command instead.
    public func runElevated(
        _ command: String,
        timeout: TimeInterval = 3600,
        consume: (@Sendable (Data) -> Void)? = nil
    ) async throws -> Output {
        try await stream(command, elevated: true, timeout: timeout, consume: consume)
    }

    // MARK: - Transport

    private func stream(
        _ command: String,
        elevated: Bool,
        timeout: TimeInterval,
        consume: (@Sendable (Data) -> Void)?
    ) async throws -> Output {
        let transport: SFTPTransport
        if elevated {
            guard let elevation else {
                throw RemoteShellError.failed(
                    "This connection cannot elevate: no sudo provider is configured."
                )
            }
            guard let privileged = await elevation.elevatedTransport(running: command) else {
                throw RemoteShellError.failed(
                    "The server refused to elevate: no usable password is stored, or sudo is disabled for this connection."
                )
            }
            try await privileged.open()
            transport = privileged
        } else {
            let plain = ProcessSFTPTransport(arguments: sshArguments(command), password: password)
            try await plain.open()
            transport = plain
        }
        defer { transport.close() }

        var collected = Data()
        let streaming = consume != nil
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let chunk = try transport.read(maxLength: 64 * 1024) else { break }
            // When the caller streams to a file, holding a second copy of a
            // multi-gigabyte archive in memory would defeat the purpose.
            if !streaming { collected.append(chunk) }
            consume?(chunk)
        }
        if Date() >= deadline {
            throw RemoteShellError.timedOut(timeout)
        }
        return Output(stdout: collected, stderr: transport.stderrText())
    }

    /// `ssh … <host> "<command>"`: the command is one argv entry, so the server's
    /// shell receives it intact.
    private func sshArguments(_ command: String) -> [String] {
        var args = ["-T"]
        args += ["-o", "NumberOfPasswordPrompts=1"]
        args += ["-o", "StrictHostKeyChecking=accept-new"]
        args += ["-o", "ConnectTimeout=20"]
        if port > 0, port != 22 { args += ["-p", String(port)] }
        let key = identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { args += ["-i", (key as NSString).expandingTildeInPath] }
        if let controlPath {
            // Reuse one authenticated connection. `auto` creates it on the first
            // call and reuses it afterwards; `ControlPersist` keeps it alive between
            // samples so authentication is paid once, not every five seconds.
            args += ["-o", "ControlMaster=auto"]
            args += ["-o", "ControlPath=" + controlPath]
            args += ["-o", "ControlPersist=300"]
        }
        args.append(username.isEmpty ? host : "\(username)@\(host)")
        args.append("/bin/sh -c " + ShellQuote.single(command))
        return args
    }

    /// Closes the shared connection, if this shell opened one.
    ///
    /// `ssh -O exit` is the supported way: it asks the master to shut down and
    /// unlinks its socket. Deleting the socket file would leave the master process
    /// running and unreachable.
    public func closeControlMaster() {
        guard let controlPath else { return }
        var args = ["ssh", "-o", "ControlPath=" + controlPath, "-O", "exit"]
        args.append(username.isEmpty ? host : "\(username)@\(host)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = Array(args.dropFirst())
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }
}

extension RemoteShell {
    /// The socket path for a control master, unique per user+host+port.
    ///
    /// Hashed rather than concatenated: a host name can exceed the 104-byte
    /// `sockaddr_un` limit, and an over-long path makes ssh fail with a message
    /// that says nothing about sockets.
    public static func controlPath(for host: String, port: Int, username: String, in directory: URL) -> String {
        let identity = "\(username)@\(host):\(port)"
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in identity.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        return directory.appendingPathComponent(String(format: "%016llx.sock", hash)).path
    }
}

public enum RemoteShellError: Error, LocalizedError {
    case timedOut(TimeInterval)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let seconds):
            return "The server did not finish within \(Int(seconds))s."
        case .failed(let message):
            return message.isEmpty ? "The command failed on the server." : message
        }
    }
}

/// Single-quotes a string for POSIX `sh`.
///
/// A shell command assembled from file names must survive names containing
/// spaces, quotes, `$` and newlines — an unquoted path is a command injection on
/// a remote server, not a cosmetic bug.
public enum ShellQuote {
    public static func single(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
