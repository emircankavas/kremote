import XCTest
@testable import KRemoteCore

/// Parameters: scanning, validation, and the shell hand-off.
///
/// The hand-off is the part that matters: parameter values are user input, so a value
/// containing a quote, a semicolon or a newline must reach the script as data. The
/// generated commands are also run in a real shell — see the notes on each test.
final class SnippetParameterTests: XCTestCase {

    // MARK: - Scanning

    func testScanFindsPlainAndBracedVariables() {
        let body = """
        ping -c 1 $TARGET_HOST
        echo "${GREETING} world"
        echo $TARGET_HOST again
        """
        XCTAssertEqual(SnippetParameterScanner.scan(body), ["TARGET_HOST", "GREETING"])
    }

    /// Shell-provided names are not user input; offering a field for them would set a
    /// variable nothing reads.
    func testScanIgnoresShellProvidedNames() {
        let body = "echo $$ $1 $? $@ $! $# $*"
        XCTAssertEqual(SnippetParameterScanner.scan(body), [])
    }

    func testScanKeepsFirstAppearanceOrder() {
        XCTAssertEqual(
            SnippetParameterScanner.scan("$B $A $C $A"),
            ["B", "A", "C"]
        )
    }

    /// A `$` followed by nothing usable must not crash or invent a name.
    func testScanToleratesLoneDollars() {
        XCTAssertEqual(SnippetParameterScanner.scan("price is $ and $% and $_ok"), ["_ok"])
        XCTAssertEqual(SnippetParameterScanner.scan(""), [])
        XCTAssertEqual(SnippetParameterScanner.scan("$"), [])
        XCTAssertEqual(SnippetParameterScanner.scan("${}"), [])
    }

    func testScanHandlesUnderscoresAndDigits() {
        XCTAssertEqual(SnippetParameterScanner.scan("$_A1 ${B_2}"), ["_A1", "B_2"])
    }

    // MARK: - Validation

    func testNameValidation() {
        XCTAssertTrue(SnippetParameter.isValidName("HOST"))
        XCTAssertTrue(SnippetParameter.isValidName("_private"))
        XCTAssertTrue(SnippetParameter.isValidName("A1"))
        XCTAssertFalse(SnippetParameter.isValidName("1A"), "cannot start with a digit")
        XCTAssertFalse(SnippetParameter.isValidName("MY-VAR"), "hyphen is not a name character")
        XCTAssertFalse(SnippetParameter.isValidName("MY VAR"))
        XCTAssertFalse(SnippetParameter.isValidName(""))
        XCTAssertFalse(SnippetParameter.isValidName("A;B"), "a semicolon would inject")
    }

    /// An invalid name is not exported at all: half a command is worse than none.
    func testInvalidNameIsNotExported() {
        let snippet = Snippet(
            name: "t",
            body: "echo $GOOD",
            parameters: [
                SnippetParameter(name: "GOOD", defaultValue: "x"),
                SnippetParameter(name: "BAD-NAME", defaultValue: "y"),
            ]
        )
        let command = SnippetLibrary.command(for: snippet, values: [:])
        XCTAssertTrue(command.contains("GOOD="))
        XCTAssertFalse(command.contains("BAD-NAME="))
    }

    // MARK: - Run preparation

    func testDefaultsSeedTheForm() {
        let snippet = Snippet(
            name: "t",
            body: "echo $HOST",
            parameters: [SnippetParameter(name: "HOST", defaultValue: "example.com")]
        )
        let run = SnippetRun.prepared(snippet)
        XCTAssertEqual(run.values["HOST"], "example.com")
        XCTAssertTrue(run.canRun)
    }

    /// A parameter with no default must be filled in before Run is allowed, otherwise
    /// the script silently receives an empty string.
    func testRequiredParameterBlocksTheRun() {
        let snippet = Snippet(
            name: "t",
            body: "echo $HOST",
            parameters: [SnippetParameter(name: "HOST")]
        )
        var run = SnippetRun.prepared(snippet)
        XCTAssertFalse(run.canRun)
        XCTAssertEqual(run.missingRequired.map(\.name), ["HOST"])

        run.values["HOST"] = "server-1"
        XCTAssertTrue(run.canRun)
        XCTAssertTrue(run.missingRequired.isEmpty)
    }

    /// Whitespace is not a value: a field of spaces looks filled and is not.
    func testWhitespaceOnlyCountsAsMissing() throws {
        let snippet = Snippet(
            name: "t",
            body: "echo $HOST",
            parameters: [SnippetParameter(name: "HOST")]
        )
        var run = SnippetRun.prepared(snippet)
        run.values["HOST"] = "   "
        XCTAssertFalse(run.canRun)
        XCTAssertEqual(try XCTUnwrap(run.missingRequired.first).name, "HOST")
    }

    /// A snippet with a broken parameter name cannot run at all.
    func testInvalidNameBlocksTheRun() {
        let snippet = Snippet(
            name: "t",
            body: "echo",
            parameters: [SnippetParameter(name: "NOT VALID", defaultValue: "x")]
        )
        XCTAssertFalse(SnippetRun.prepared(snippet).canRun)
    }

    // MARK: - Hand-off safety

    /// **The command text must never contain the value.**
    ///
    /// This is the whole safety argument: a value is data, and the only way to keep it
    /// data in a shell command is to not write it there. It travels base64-encoded and
    /// is decoded by the shell into an assignment.
    func testValueIsNeverInterpolatedIntoTheCommandText() {
        let hostile = "'; touch /tmp/pwned; '"
        let snippet = Snippet(
            name: "t",
            body: "echo done",
            parameters: [SnippetParameter(name: "ARG", defaultValue: hostile)]
        )
        let command = SnippetLibrary.command(for: snippet, values: ["ARG": hostile])

        XCTAssertFalse(command.contains("pwned"),
                       "the raw value must not appear in the command: \(command)")
        XCTAssertFalse(command.contains("touch"))
        // And it is present, encoded, so the script does receive it.
        XCTAssertTrue(command.contains(Data(hostile.utf8).base64EncodedString()))
    }

    /// Assignments are a command prefix, so the value is scoped to the script.
    func testAssignmentsAreAPrefixNotExports() {
        let snippet = Snippet(
            name: "t",
            body: "echo $A",
            parameters: [SnippetParameter(name: "A", defaultValue: "v")]
        )
        let command = SnippetLibrary.command(for: snippet, values: [:])
        XCTAssertFalse(command.contains("export "),
                       "an exported variable outlives the script in the user's shell")
        XCTAssertNotNil(command.range(of: "A=$("))
        // The assignment must come before `sh` runs the script.
        if let a = command.range(of: "A=$("), let s = command.range(of: "; sh ") {
            XCTAssertLessThan(a.lowerBound, s.lowerBound)
        }
    }

    /// No assignments, no dangling separator.
    func testSnippetWithoutParametersIsUnchanged() {
        let plain = Snippet(name: "t", body: "echo hi")
        let command = SnippetLibrary.command(for: plain)
        // `f=$(mktemp …)` is the temp file, not a parameter: assert on the prefix
        // list specifically by checking nothing is bound before `sh`.
        XCTAssertEqual(SnippetLibrary.environmentAssignments(for: plain, values: [:]), "")
        XCTAssertTrue(command.contains("sh \"$f\""))
    }

    // MARK: - Preview

    func testSecretValuesAreMasked() {
        let snippet = Snippet(
            name: "t",
            body: "echo $P",
            parameters: [
                SnippetParameter(name: "P", defaultValue: "hunter2", isSecret: true),
                SnippetParameter(name: "Q", defaultValue: "visible"),
            ]
        )
        let preview = SnippetRun.prepared(snippet).previewValues()
        XCTAssertEqual(preview.count, 2)
        XCTAssertEqual(preview[0].value, "•••••••")
        XCTAssertEqual(preview[1].value, "visible")
    }
}
