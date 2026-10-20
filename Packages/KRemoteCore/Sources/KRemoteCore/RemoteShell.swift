import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Runs a command on the server over the connection's own `ssh`, with its output
/// streamed back.
///
/// SFTP v3 cannot ask the server to run a program, and archiving on the server is
/// worth a second connection: a `.tar.gz` is transferred instead of the
/// uncompressed files, and no temporary copy is written to this Mac's disk.
///
/// This is deliberately a small, separate transport rather than a method on
/// `SFTPClient`: the subsystem and a shell command are two different channels on
/// the same server, and mixing them would make the SFTP request ids ambiguous.
public final class RemoteShell: @unchecked Sendable {
    public struct Output: Sendable {
        public let status: Int32
        public let stdout: Data
        public let stderr: String
    }

    private let host: String
    private let port: Int
    private let username: String
    private let identityFile: String
    private let password: String

    public init(host: String, port: Int, username: String, identityFile: String, password: String) {
        self.host = host
        self.port = port
        self.username = username
        self.identityFile = identityFile
        self.password = password
    }

    /// Streams `command`'s stdout to `consume` as it arrives.
    ///
    /// `consume` is called on a background queue, so a caller writing to a file
    /// never stalls the reader. The command is wrapped in `/bin/sh -c` on the
    /// server so quoting is the caller's business, not ssh's.
    public func run(
        _ command: String,
        timeout: TimeInterval = 300,
        consume: (@Sendable (Data) -> Void)? = nil
    ) async throws -> Output {
        var args = ["-T"]
        args += ["-o", "NumberOfPasswordPrompts=1"]
        args += ["-o", "StrictHostKeyChecking=accept-new"]
        args += ["-o", "ConnectTimeout=20"]
        if port > 0, port != 22 { args += ["-p", String(port)] }
        let key = identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { args += ["-i", (key as NSString).expandingTildeInPath] }
        args.append(username.isEmpty ? host : "\(username)@\(host)")
        args.append("/bin/sh -c \(ShellQuote.single(command))")

        let transport = ProcessSFTPTransport(arguments: args, password: password)
        try await transport.open()
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
        // Anything still buffered after the deadline is a timeout, not a result.
        if Date() >= deadline {
            throw RemoteShellError.timedOut(timeout)
        }
        let stderr = transport.stderrText()
        return Output(status: 0, stdout: collected, stderr: stderr)
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
