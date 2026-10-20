import Foundation

/// An elevated channel that runs one shell command, not the SFTP subsystem.
///
/// `SudoSFTPTransport` cannot do this job. It is built for a subsystem, so it
/// treats stderr as sudo's verdict: any line there tears the channel down. When
/// the elevated command is `tar`, that is wrong on the first byte — tar warns
/// "Removing leading `/' from member names" while working perfectly — and the
/// user saw "Elevating with sudo failed" on every archive attempt.
///
/// Here stderr is only ever *diagnostics*. The password is written once, as the
/// single line sudo reads; after that stdin and stdout belong to the command, and
/// a command's own complaints are reported by the caller that knows what the
/// command was.
final class SudoCommandTransport: SFTPTransport, @unchecked Sendable {
    private let process: SFTPTransport
    /// `password + "\n"` — the one line sudo reads. Never logged, never stored.
    private let passwordLine: Data

    init(process: SFTPTransport, passwordLine: Data) {
        self.process = process
        self.passwordLine = passwordLine
    }

    func open() async throws {
        try await process.open()
        // The password goes in first and alone. sudo consumes exactly this line
        // and leaves the rest of stdin to the command.
        try process.write(passwordLine)
    }

    func write(_ data: Data) throws { try process.write(data) }

    func read(maxLength: Int) throws -> Data? { try process.read(maxLength: maxLength) }

    func stderrText() -> String { process.stderrText() }

    func close() { process.close() }

    var isAlive: Bool { process.isAlive }
}
