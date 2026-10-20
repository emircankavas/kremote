import XCTest
@testable import KRemoteCore

/// The elevated channel that runs a command must not police stderr.
///
/// `SudoSFTPTransport` does — correctly, for a subsystem — and reusing it for
/// `tar` meant every archive was torn down by tar's first warning, reaching the
/// user as "Elevating with sudo failed" with a temp directory as the explanation.
final class SudoCommandTransportTests: XCTestCase {

    /// Records what the transport did, so the assertions are about behaviour
    /// rather than about a real ssh process.
    private final class Recorder: SFTPTransport, @unchecked Sendable {
        var opened = false
        var written: [Data] = []
        var closed = false
        var stderr = ""
        var chunks: [Data?] = []

        func open() async throws { opened = true }
        func write(_ data: Data) throws { written.append(data) }
        func read(maxLength: Int) throws -> Data? {
            chunks.isEmpty ? nil : chunks.removeFirst()
        }
        func stderrText() -> String { stderr }
        func close() { closed = true }
        var isAlive: Bool { !closed }
    }

    private func make(_ recorder: Recorder) -> SudoCommandTransport {
        SudoCommandTransport(
            process: recorder,
            passwordLine: Data("hunter2\n".utf8)
        )
    }

    /// The password is written first and alone: sudo consumes exactly that line
    /// and leaves the rest of stdin to the command.
    func testPasswordIsTheOnlyThingWrittenBeforeOutput() async throws {
        let recorder = Recorder()
        try await make(recorder).open()

        XCTAssertTrue(recorder.opened)
        XCTAssertEqual(recorder.written, [Data("hunter2\n".utf8)])
    }

    /// The bug: stdout keeps flowing no matter what the command puts on stderr.
    func testCommandStderrDoesNotStopTheStream() async throws {
        let recorder = Recorder()
        let transport = make(recorder)
        try await transport.open()

        recorder.stderr = "tar: Removing leading `/' from member names"
        recorder.chunks = [Data("ARCHIVE".utf8), Data("-BYTES".utf8), nil]

        var collected = Data()
        while let chunk = try transport.read(maxLength: 4096) {
            collected.append(chunk)
        }

        XCTAssertEqual(String(decoding: collected, as: UTF8.self), "ARCHIVE-BYTES")
        XCTAssertFalse(recorder.closed, "stderr must not close the channel")
    }

    /// A command's stderr is still available afterwards — the caller needs it to
    /// explain a failure — but reading it is not what decides the outcome.
    func testStderrIsDiagnostics() async throws {
        let recorder = Recorder()
        let transport = make(recorder)
        try await transport.open()
        recorder.stderr = "tar: /root/secret: Cannot open: Permission denied"

        XCTAssertTrue(transport.stderrText().contains("Permission denied"))
    }
}
