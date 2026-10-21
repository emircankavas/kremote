import XCTest
@testable import KRemoteCore

/// The editor's conflict rule, the multi-exec ordering, and the tools catalogue.
///
/// These are the parts that decide whether a feature is safe rather than merely
/// present: a save that clobbers a colleague's change, or a results list that
/// reshuffles so the odd host out is invisible.
final class RemoteEditingTests: XCTestCase {

    // MARK: - Binary detection

    /// A NUL byte is what `git`, `grep` and `file` all use, and is the difference
    /// between refusing a file and corrupting it.
    func testBinaryDetection() {
        XCTAssertTrue(RemoteFileDocument.looksBinary(Data([0x7f, 0x45, 0x4c, 0x46, 0x00, 0x01])))
        XCTAssertFalse(RemoteFileDocument.looksBinary(Data("#!/bin/sh\necho hi\n".utf8)))
        XCTAssertFalse(RemoteFileDocument.looksBinary(Data()))
        // The heuristic only inspects the head: a NUL deep inside a huge file is not
        // worth reading the whole thing for.
        var big = Data(repeating: 0x41, count: 9000)
        big.append(0)
        XCTAssertFalse(RemoteFileDocument.looksBinary(big))
    }

    // MARK: - Document state

    private func document(
        _ text: String,
        size: UInt64? = 10,
        modified: Date? = Date(timeIntervalSince1970: 1000)
    ) -> RemoteFileDocument {
        RemoteFileDocument.make(
            path: "/etc/hosts",
            data: Data(text.utf8),
            size: size,
            modified: modified
        )
    }

    func testDirtyTrackingIsExact() {
        var doc = document("one\n")
        XCTAssertFalse(doc.isDirty)
        doc.text = "one\ntwo\n"
        XCTAssertTrue(doc.isDirty)
        // Restoring the original text is not dirty, even after edits: the user expects
        // undo-to-saved to clear the dot in the title bar.
        doc.text = "one\n"
        XCTAssertFalse(doc.isDirty)
    }

    /// The whole reason the original size and mtime travel with the document.
    func testConflictWhenModifiedTimeChanged() {
        let doc = document("one\n", size: 10, modified: Date(timeIntervalSince1970: 1000))
        XCTAssertFalse(doc.conflictsWith(currentSize: 10, currentModified: Date(timeIntervalSince1970: 1000)))
        XCTAssertTrue(doc.conflictsWith(currentSize: 10, currentModified: Date(timeIntervalSince1970: 1001)))
    }

    func testConflictWhenSizeChanged() {
        let doc = document("one\n", size: 10, modified: Date(timeIntervalSince1970: 1000))
        XCTAssertTrue(doc.conflictsWith(currentSize: 11, currentModified: Date(timeIntervalSince1970: 1000)))
        XCTAssertFalse(doc.conflictsWith(currentSize: 10, currentModified: Date(timeIntervalSince1970: 1000)))
    }

    /// Unknown metadata must not block a save: a server that does not report mtime is
    /// not a reason to make the editor read-only.
    func testMissingMetadataDoesNotConflict() {
        let doc = document("one\n", size: nil, modified: nil)
        XCTAssertFalse(doc.conflictsWith(currentSize: 99, currentModified: Date(timeIntervalSince1970: 99)))
    }

    /// Lossy decoding is flagged so the UI can warn before a save rewrites the file in
    /// a different encoding than it arrived in.
    func testInvalidUTF8IsFlaggedRatherThanSilentlyReplaced() {
        // 0xFF is not valid UTF-8 and is not a NUL, so it is text-ish but undecodable.
        let doc = RemoteFileDocument.make(
            path: "/tmp/x",
            data: Data([0x61, 0xff, 0x62]),
            size: 3,
            modified: Date(timeIntervalSince1970: 1)
        )
        XCTAssertTrue(doc.hadDecodingLoss)
        XCTAssertFalse(doc.isBinary)
    }

    func testDisplayNameIsTheLastComponent() {
        XCTAssertEqual(document("x").displayName, "hosts")
    }

    // MARK: - Multi-execution

    /// Results come back in the order the targets were given: a list that reshuffles
    /// as servers answer is unreadable when scanning for the odd host out.
    func testResultsKeepTargetOrder() async {
        // Every target is unreachable, so the run fails fast and no server is touched.
        let targets = (0..<5).map { index in
            MultiExecution.Target(
                nodeID: UUID(),
                name: "host-\(index)",
                host: "127.0.0.1",
                port: 1,
                username: "nobody",
                password: "x"
            )
        }
        let results = await MultiExecution.run(command: "true", targets: targets, timeout: 2)
        XCTAssertEqual(results.count, 5)
        XCTAssertEqual(results.map(\.name), targets.map(\.name))
    }

    /// An empty command is a no-op, not five connections that do nothing.
    func testEmptyCommandRunsNothing() async {
        let targets = [MultiExecution.Target(nodeID: UUID(), name: "a", host: "127.0.0.1", port: 1)]
        let results = await MultiExecution.run(command: "   ", targets: targets)
        XCTAssertTrue(results.isEmpty)
    }

    /// A failure is a result, not an exception: one dead host must not hide the rest.
    func testFailureBecomesAResult() async {
        let target = MultiExecution.Target(
            nodeID: UUID(), name: "dead", host: "127.0.0.1", port: 1
        )
        let results = await MultiExecution.run(command: "true", targets: [target], timeout: 2)
        let result = try? XCTUnwrap(results.first)
        XCTAssertNotNil(result)
        XCTAssertFalse(result?.error.isEmpty ?? true)
        XCTAssertNil(result?.exitCode)
        XCTAssertFalse(result?.succeeded ?? true)
    }

    func testSucceededRequiresNoErrorAndZeroExit() {
        let base = MultiExecResult(
            nodeID: UUID(), name: "n", host: "h",
            output: "", error: "", exitCode: 0, duration: 0
        )
        XCTAssertTrue(base.succeeded)
        XCTAssertFalse(MultiExecResult(
            nodeID: UUID(), name: "n", host: "h",
            output: "", error: "", exitCode: 1, duration: 0
        ).succeeded)
        XCTAssertFalse(MultiExecResult(
            nodeID: UUID(), name: "n", host: "h",
            output: "", error: "refused", exitCode: nil, duration: 0
        ).succeeded)
    }

    /// stderr belongs in the output: a command that warned and succeeded must not look
    /// as if it said nothing.
    func testStderrIsAppendedNotDiscarded() {
        let base = MultiExecResult(
            nodeID: UUID(), name: "n", host: "h",
            output: "ok\n", error: "", exitCode: 0, duration: 0
        )
        let combined = base.withStderr("warning: something")
        XCTAssertTrue(combined.output.contains("ok"))
        XCTAssertTrue(combined.output.contains("warning: something"))
        XCTAssertFalse(combined.output.contains("\n\n"))
    }
}
