import XCTest
@testable import KRemoteCore

/// Snippet construction and storage.
///
/// The command builder is the part that can silently corrupt a script: a body with a
/// quote, a heredoc or a non-ASCII character must reach the server byte for byte. The
/// generated commands were also run against a real macOS shell and a real Linux shell
/// (8 bodies: quotes, `$HOME`, `$(...)`, heredoc, UTF-8, exit codes) — these tests pin
/// the construction, the shell runs pinned the behaviour.
final class SnippetTests: XCTestCase {

    private func snippet(_ body: String) -> Snippet {
        Snippet(name: "t", body: body)
    }

    // MARK: - Command construction

    func testCommandCarriesTheBodyAsBase64() {
        let command = SnippetLibrary.command(for: snippet("echo hello"))
        let expected = Data("echo hello".utf8).base64EncodedString()
        XCTAssertTrue(command.contains(expected),
                      "the body must travel base64-encoded, not quoted")
    }

    /// A body containing a single quote is the classic way a naive quoter breaks.
    /// Base64 cannot, and this pins that the quote never appears in the command.
    func testBodyWithQuotesIsNotInterpolated() {
        let body = "echo \"it's fine\"; echo 'and this too'"
        let command = SnippetLibrary.command(for: snippet(body))
        XCTAssertFalse(command.contains("it's"), "the raw body must not be in the command")
        XCTAssertTrue(command.contains(Data(body.utf8).base64EncodedString()))
    }

    /// Any byte a script can hold, including newlines and UTF-8.
    func testMultilineUnicodeBodyRoundTrips() {
        let body = "if [ -d /tmp ]; then\n  echo 'türkçe ✓'\nfi"
        let command = SnippetLibrary.command(for: snippet(body))
        guard let encoded = command.components(separatedBy: "'").first(where: {
            !$0.isEmpty && Data(base64Encoded: $0) != nil
        }), let decoded = Data(base64Encoded: encoded) else {
            return XCTFail("no base64 payload in: \(command)")
        }
        XCTAssertEqual(String(decoding: decoded, as: UTF8.self), body)
    }

    /// The file must be removed even when the script fails, or a shared server keeps
    /// an executable copy of the user's script.
    func testCommandCleansUpUnconditionally() {
        let command = SnippetLibrary.command(for: snippet("exit 1"))
        XCTAssertTrue(command.contains("rm -f"))
        // Cleanup runs after the status is captured, so the exit code survives it.
        let removal = command.range(of: "rm -f")
        let capture = command.range(of: "rc=$?")
        XCTAssertNotNil(removal)
        XCTAssertNotNil(capture)
        if let removal, let capture {
            XCTAssertLessThan(capture.lowerBound, removal.lowerBound,
                              "the exit status must be captured before the file is removed")
        }
    }

    /// The exit code of the script must be the command's exit code, otherwise a
    /// failing snippet looks like it succeeded.
    func testExitStatusIsPropagated() {
        let command = SnippetLibrary.command(for: snippet("exit 7"))
        XCTAssertTrue(command.hasSuffix("exit $rc"), "got: \(command)")
    }

    /// `$$` keeps two snippets run at the same moment from overwriting each other's
    /// temp file.
    func testTempPathIsPerShell() {
        let command = SnippetLibrary.command(for: snippet("echo"))
        XCTAssertTrue(command.contains("kremote-snippet-$$.sh"),
                      "the pid must be in the path so concurrent runs do not collide")
    }

    /// BSD `base64` spells decode `-D`; GNU spells it `-d`. `-d` is the one both
    /// accept, so it is what ships — checked on macOS 26 and on Linux.
    func testDecoderSpellingIsPortable() {
        XCTAssertTrue(SnippetLibrary.decoder.hasSuffix("-d"))
        XCTAssertFalse(SnippetLibrary.decoder.contains("-D"))
    }

    // MARK: - Runnable / destructive

    func testEmptySnippetIsNotRunnable() {
        XCTAssertFalse(snippet("").isRunnable)
        XCTAssertFalse(snippet("   \n\t ").isRunnable)
        XCTAssertTrue(snippet("echo").isRunnable)
    }

    /// The heavier warning is never a substitute for confirmation, but "this deletes
    /// things" reads differently from "this lists a directory".
    func testDestructiveDetection() {
        XCTAssertTrue(SnippetLibrary.isDestructive(snippet("rm -rf /tmp/x")))
        XCTAssertTrue(SnippetLibrary.isDestructive(snippet("sudo mkfs.ext4 /dev/sdb1")))
        XCTAssertTrue(SnippetLibrary.isDestructive(snippet("shutdown -h now")))
        XCTAssertTrue(SnippetLibrary.isDestructive(snippet("dd if=/dev/zero of=/dev/sda")))
        XCTAssertFalse(SnippetLibrary.isDestructive(snippet("df -h")))
        XCTAssertFalse(SnippetLibrary.isDestructive(snippet("systemctl status nginx")))
    }

    // MARK: - Preview

    func testPreviewShowsTheScriptNotASummary() {
        let preview = SnippetLibrary.preview(of: snippet("echo one\necho two"))
        XCTAssertEqual(preview, "echo one\necho two")
    }

    /// A long script is truncated with a count, never silently cut.
    func testLongPreviewSaysHowMuchIsHidden() {
        let body = (1...30).map { "echo \($0)" }.joined(separator: "\n")
        let preview = SnippetLibrary.preview(of: snippet(body), maximumLines: 5)
        XCTAssertTrue(preview.contains("… 25 more lines"), "got: \(preview)")
    }

    // MARK: - Storage

    func testSnippetsSurviveARoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snippets-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SnippetStore(fileURL: url)
        XCTAssertNil(try store.load(), "no file yet means no snippets, not an error")

        let saved = [
            Snippet(name: "Disk", body: "df -h", sortIndex: 0),
            Snippet(name: "Uptime", body: "uptime", sortIndex: 1),
        ]
        try store.save(saved)

        let loaded = try XCTUnwrap(try store.load())
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.map(\.name), ["Disk", "Uptime"])
        XCTAssertEqual(loaded[0].body, "df -h")
        XCTAssertEqual(loaded[0].id, saved[0].id, "ids must be stable across a save")
    }

    /// Snippets live in their own file, so a broken tree file cannot take them with
    /// it — and vice versa.
    func testSnippetFileIsSeparateFromTheTree() {
        let snippets = SnippetStore.defaultFileURL()
        let tree = NodeStore.defaultFileURL()
        XCTAssertNotEqual(snippets, tree)
        XCTAssertTrue(snippets.lastPathComponent.hasSuffix("snippets.json"))
    }
}
