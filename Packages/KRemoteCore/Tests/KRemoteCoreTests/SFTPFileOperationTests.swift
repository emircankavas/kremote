import XCTest
@testable import KRemoteCore

/// The permission sheet's arithmetic. These rules decide what mode a file ends up
/// with, so they are tested here rather than trusted to the view.
final class PermissionSetTests: XCTestCase {

    func testModeBitsRoundTrip() {
        for mode: UInt16 in [0o600, 0o644, 0o755, 0o777, 0o000, 0o4755, 0o2750, 0o1777] {
            XCTAssertEqual(PermissionSet(modeBits: mode).modeBits, mode, "mode \(String(mode, radix: 8))")
        }
    }

    func testClassesDecodeFromBits() {
        let set = PermissionSet(modeBits: 0o640)
        XCTAssertEqual(set.owner, PermissionClass(read: true, write: true, execute: false))
        XCTAssertEqual(set.group, PermissionClass(read: true, write: false, execute: false))
        XCTAssertEqual(set.other, PermissionClass())
        XCTAssertEqual(set.symbolic, "rw-r-----")
    }

    func testOctalIsNotZeroPadded() {
        XCTAssertEqual(PermissionSet(modeBits: 0o644).octal, "644")
        XCTAssertEqual(PermissionSet(modeBits: 0o755).octal, "755")
        XCTAssertEqual(PermissionSet(modeBits: 0o4755).octal, "4755")
        XCTAssertEqual(PermissionSet(modeBits: 0).octal, "0")
    }

    func testParseAcceptsThreeAndFourDigitsWithOptionalLeadingZero() {
        XCTAssertEqual(PermissionSet.parse(octal: "644")?.modeBits, 0o644)
        XCTAssertEqual(PermissionSet.parse(octal: "0644")?.modeBits, 0o644)
        XCTAssertEqual(PermissionSet.parse(octal: " 755 ")?.modeBits, 0o755)
        XCTAssertEqual(PermissionSet.parse(octal: "4755")?.modeBits, 0o4755)
        XCTAssertEqual(PermissionSet.parse(octal: "0o640")?.modeBits, 0o640)
        XCTAssertEqual(PermissionSet.parse(octal: "0")?.modeBits, 0)
    }

    func testParseRejectsWhatIsNotAMode() {
        // A digit above 7, letters, an empty field, and a five-digit number are all
        // refused rather than silently reinterpreted.
        XCTAssertNil(PermissionSet.parse(octal: "8"))
        XCTAssertNil(PermissionSet.parse(octal: "abc"))
        XCTAssertNil(PermissionSet.parse(octal: ""))
        XCTAssertNil(PermissionSet.parse(octal: "77777"))
        XCTAssertNil(PermissionSet.parse(octal: "-644"))
    }

    func testCheckboxEditsMoveTheNumber() {
        var set = PermissionSet(modeBits: 0o644)
        set.owner.execute = true
        set.group.execute = true
        set.other.execute = true
        XCTAssertEqual(set.octal, "755")
        // Clearing "other read" on 755 leaves r-- → 1, so the mode is 751.
        set.other.read = false
        XCTAssertEqual(set.octal, "751")
        set.other.execute = false
        XCTAssertEqual(set.octal, "750")
    }

    func testEmptyModeIsFlagged() {
        XCTAssertTrue(PermissionSet(modeBits: 0).isDeniedToEveryone)
        XCTAssertFalse(PermissionSet(modeBits: 0o400).isDeniedToEveryone)
    }

    func testSetuidIsKeptOutOfTheOctalOfPlainModes() {
        let set = PermissionSet(owner: PermissionClass(read: true, write: true, execute: true),
                                group: PermissionClass(bits: 0o5),
                                other: PermissionClass(bits: 0o5))
        XCTAssertEqual(set.modeBits, 0o755)
        XCTAssertFalse(set.setuid)
    }
}

/// "Keep Both" naming. The rule has to be Finder's, because that is what a user
/// expects when they pick it, and it must never produce a name that already exists.
final class ConflictResolverTests: XCTestCase {

    func testFreeNameIsUnchanged() {
        XCTAssertEqual(ConflictResolver.keepBothName(for: "a.txt", existing: []), "a.txt")
    }

    func testNumbersBeforeTheExtension() {
        XCTAssertEqual(
            ConflictResolver.keepBothName(for: "report.txt", existing: ["report.txt"]),
            "report 2.txt"
        )
        XCTAssertEqual(
            ConflictResolver.keepBothName(for: "report.txt", existing: ["report.txt", "report 2.txt"]),
            "report 3.txt"
        )
    }

    func testExistingNumberContinuesInsteadOfStacking() {
        XCTAssertEqual(
            ConflictResolver.keepBothName(for: "report 2.txt", existing: ["report 2.txt"]),
            "report 3.txt"
        )
    }

    func testNameWithoutExtension() {
        XCTAssertEqual(
            ConflictResolver.keepBothName(for: "notes", existing: ["notes"]),
            "notes 2"
        )
    }

    func testDotfileIsTreatedAsAStem() {
        XCTAssertEqual(
            ConflictResolver.keepBothName(for: ".bashrc", existing: [".bashrc"]),
            ".bashrc 2"
        )
    }

    func testComparisonIsCaseInsensitive() {
        // macOS volumes usually are, so "Report.TXT" must count as taken.
        XCTAssertEqual(
            ConflictResolver.keepBothName(for: "report.txt", existing: ["REPORT.TXT"]),
            "report 2.txt"
        )
    }

    func testResultIsNeverAlreadyTaken() {
        let existing: Set<String> = ["a.txt", "a 2.txt", "a 3.txt", "a 4.txt"]
        let name = ConflictResolver.keepBothName(for: "a.txt", existing: existing)
        XCTAssertEqual(name, "a 5.txt")
        XCTAssertFalse(existing.contains(name))
    }
}

/// The one summary a partly-failed batch shows. Getting the wording wrong here is
/// how a user ends up thinking nothing worked when most of it did.
final class BatchOutcomeTests: XCTestCase {

    func testAllSucceeded() {
        var outcome = BatchOutcome()
        outcome.recordSuccess("a")
        outcome.recordSuccess("b")
        XCTAssertTrue(outcome.isCompleteSuccess)
        XCTAssertEqual(outcome.headline, "2 items completed")
        XCTAssertEqual(outcome.detail, "Completed:\n  a\n  b")
    }

    func testPartialFailureNamesBothSidesWithTheServerText() {
        var outcome = BatchOutcome()
        outcome.recordSuccess("ok.txt")
        outcome.recordFailure("root.txt", error: SFTPError.status(.permissionDenied, message: "Permission denied."))
        XCTAssertFalse(outcome.isCompleteSuccess)
        XCTAssertEqual(outcome.headline, "1 of 2 items completed")
        XCTAssertTrue(outcome.detail.contains("Failed:"))
        XCTAssertTrue(outcome.detail.contains("root.txt — Permission denied"))
        XCTAssertTrue(outcome.detail.contains("Completed:"))
        XCTAssertTrue(outcome.detail.contains("ok.txt"))
        XCTAssertEqual(outcome.failedNames, ["root.txt"])
    }

    func testEveryFailureListedNotJustTheFirst() {
        var outcome = BatchOutcome()
        outcome.recordFailure("a", error: SFTPError.status(.permissionDenied, message: ""))
        outcome.recordFailure("b", error: SFTPError.status(.permissionDenied, message: ""))
        XCTAssertEqual(outcome.headline, "2 items could not be completed")
        XCTAssertEqual(outcome.failedNames, ["a", "b"])
        XCTAssertEqual(outcome.detail.components(separatedBy: "  a — ").count, 2)
        XCTAssertTrue(outcome.detail.contains("  b — "))
    }

    func testSkippedItemsAreReportedSeparatelyFromFailures() {
        var outcome = BatchOutcome()
        outcome.skipped = ["kept.txt"]
        XCTAssertFalse(outcome.isEmpty)
        XCTAssertFalse(outcome.isCompleteSuccess)
        XCTAssertTrue(outcome.detail.contains("Not attempted:"))
        XCTAssertTrue(outcome.detail.contains("kept.txt"))
        XCTAssertTrue(outcome.failures.isEmpty)
    }

    func testCancellationDoesNotLookLikeFailure() {
        var outcome = BatchOutcome()
        outcome.recordSuccess("done.txt")
        outcome.wasCancelled = true
        outcome.skipped = ["later.txt"]
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertTrue(outcome.headline.contains("cancelled"))
    }

    func testEmptyBatchIsSilent() {
        XCTAssertTrue(BatchOutcome().isEmpty)
    }
}

/// The alert wording for a refused operation: it must say whether elevation was
/// tried, because that changes what the user has to do about it.
final class OperationFailureTextTests: XCTestCase {

    private let denied = SFTPError.status(.permissionDenied, message: "Permission denied.")

    func testDisabledSudoSaysItWasNotAttempted() {
        let message = OperationFailureText.message(
            for: denied, context: .init(elevation: .disabled)
        )
        XCTAssertTrue(message.contains("Sudo is not enabled for this connection"))
        XCTAssertTrue(message.contains("no elevated retry was made"))
    }

    func testMissingPasswordIsItsOwnReason() {
        let message = OperationFailureText.message(
            for: denied, context: .init(elevation: .noPassword)
        )
        XCTAssertTrue(message.contains("no saved password"))
    }

    func testAvailableElevationSaysTheRetryHappened() {
        let message = OperationFailureText.message(
            for: denied, context: .init(elevation: .available)
        )
        XCTAssertTrue(message.contains("retried once as root"))
        XCTAssertFalse(message.contains("Sudo is not enabled"))
    }

    func testElevationFailureCarriesTheServersWordsAndSaysItWasTried() {
        let error = SFTPError.elevationFailed(
            ElevationFailure(kind: .passwordRejected, stderr: "sudo: Authentication failed, try again.")
        )
        let message = OperationFailureText.message(for: error, context: .init(elevation: .available))
        XCTAssertTrue(message.contains("Authentication failed"))
        XCTAssertTrue(message.contains("Sudo elevation was attempted"))
    }

    func testNonPermissionFailureIsJustTheServerText() {
        let error = SFTPError.status(.noSuchFile, message: "No such file")
        let message = OperationFailureText.message(for: error, context: .init(elevation: .disabled))
        XCTAssertEqual(message, "No such file or directory — No such file")
    }

    func testTitleNamesTheItemAndTheKindOfProblem() {
        XCTAssertEqual(
            OperationFailureText.title(for: denied, subject: "root.txt"),
            "“root.txt” needs administrator rights"
        )
        XCTAssertEqual(
            OperationFailureText.title(for: TransferCancelled(), subject: "big.bin"),
            "“big.bin” was cancelled"
        )
        XCTAssertEqual(
            OperationFailureText.title(for: SFTPError.status(.noSuchFile, message: ""), subject: "gone"),
            "“gone” could not be completed"
        )
    }
}

/// `.part` naming: the guarantee that a cancelled transfer leaves nothing under the
/// real name depends on these two rules.
final class PartPathTests: XCTestCase {

    func testLocalPartSitsBesideTheTarget() {
        let target = URL(fileURLWithPath: "/tmp/downloads/report.pdf")
        let part = SFTPClient.partURL(for: target)
        XCTAssertEqual(part.deletingLastPathComponent().path, "/tmp/downloads")
        XCTAssertEqual(part.lastPathComponent, ".report.pdf.part")
    }

    func testRemotePartIsHiddenAndSitsBesideTheTarget() {
        XCTAssertEqual(SFTPClient.remotePartPath("/srv/www/index.html"), "/srv/www/.index.html.part")
        XCTAssertEqual(SFTPClient.remotePartPath("/index.html"), "/.index.html.part")
        XCTAssertEqual(SFTPClient.remotePartPath("a/b.txt"), "a/.b.txt.part")
    }

    func testRemotePartOfANormalisedPath() {
        // A path with a trailing slash or dots must not produce a part file in a
        // directory that does not exist.
        XCTAssertEqual(SFTPClient.remotePartPath("/srv/www/./x.tar"), "/srv/www/.x.tar.part")
        XCTAssertEqual(SFTPClient.remotePartPath("/srv/www/../www/y.tar"), "/srv/www/.y.tar.part")
    }
}
