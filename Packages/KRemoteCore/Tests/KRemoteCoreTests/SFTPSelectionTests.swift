import XCTest
@testable import KRemoteCore

/// The three selection gestures the SFTP window offers, tested as rules rather
/// than through a window: single click replaces, ⌘ toggles one row, ⇧ extends a
/// range from the anchor.
final class SFTPSelectionTests: XCTestCase {

    private let order = ["/a", "/b", "/c", "/d", "/e"]

    func testPlainClickReplacesTheSelectionAndMovesTheAnchor() {
        var anchor: String? = "/a"
        let selection = SFTPSelection.apply(
            .replace, to: ["/a", "/b"], anchor: &anchor, path: "/c", order: order
        )
        XCTAssertEqual(selection, ["/c"])
        XCTAssertEqual(anchor, "/c")
    }

    func testCommandClickAddsAndRemovesWithoutTouchingTheRest() {
        var anchor: String? = "/a"
        var selection: Set<String> = ["/a"]
        selection = SFTPSelection.apply(
            .toggle, to: selection, anchor: &anchor, path: "/c", order: order
        )
        XCTAssertEqual(selection, ["/a", "/c"])
        XCTAssertEqual(anchor, "/c", "⌘-click moves the anchor, as Finder does")

        selection = SFTPSelection.apply(
            .toggle, to: selection, anchor: &anchor, path: "/a", order: order
        )
        XCTAssertEqual(selection, ["/c"], "a second ⌘-click on the same row removes it")
    }

    func testShiftClickSelectsTheRangeFromTheAnchorForwards() {
        var anchor: String? = "/b"
        let selection = SFTPSelection.apply(
            .extend, to: ["/b"], anchor: &anchor, path: "/d", order: order
        )
        XCTAssertEqual(selection, ["/b", "/c", "/d"])
        XCTAssertEqual(anchor, "/b", "⇧-click must not move the anchor, or the range would collapse")
    }

    func testShiftClickSelectsTheRangeBackwards() {
        var anchor: String? = "/d"
        let selection = SFTPSelection.apply(
            .extend, to: ["/d"], anchor: &anchor, path: "/b", order: order
        )
        XCTAssertEqual(selection, ["/b", "/c", "/d"], "a backwards range is still inclusive")
    }

    func testRepeatedShiftClicksGrowAndShrinkFromTheSameAnchor() {
        var anchor: String? = "/a"
        var selection: Set<String> = ["/a"]
        selection = SFTPSelection.apply(
            .extend, to: selection, anchor: &anchor, path: "/c", order: order
        )
        XCTAssertEqual(selection, ["/a", "/b", "/c"])
        selection = SFTPSelection.apply(
            .extend, to: selection, anchor: &anchor, path: "/e", order: order
        )
        XCTAssertEqual(selection, ["/a", "/b", "/c", "/d", "/e"])
        selection = SFTPSelection.apply(
            .extend, to: selection, anchor: &anchor, path: "/b", order: order
        )
        XCTAssertEqual(selection, ["/a", "/b"], "shrinking back is allowed")
    }

    func testShiftClickWithNoAnchorBehavesLikeAPlainClick() {
        var anchor: String?
        let selection = SFTPSelection.apply(
            .extend, to: [], anchor: &anchor, path: "/c", order: order
        )
        XCTAssertEqual(selection, ["/c"])
        XCTAssertEqual(anchor, "/c")
    }

    func testShiftClickOnARowThatIsNoLongerListedBehavesLikeAPlainClick() {
        var anchor: String? = "/gone"
        let selection = SFTPSelection.apply(
            .extend, to: ["/gone"], anchor: &anchor, path: "/c", order: order
        )
        XCTAssertEqual(selection, ["/c"])
    }

    func testPruningDropsRowsThatNoLongerExist() {
        let pruned = SFTPSelection.pruned(["/a", "/gone"], to: order)
        XCTAssertEqual(pruned, ["/a"])
    }

    func testSingleReturnsNothingForAMultiSelection() {
        XCTAssertEqual(SFTPSelection.single(["/a"], order: order), "/a")
        XCTAssertNil(SFTPSelection.single(["/a", "/b"], order: order))
        XCTAssertNil(SFTPSelection.single([], order: order))
        XCTAssertNil(SFTPSelection.single(["/gone"], order: order),
                     "a selected row that is not listed is not a target")
    }

    func testSelectAllUsesOnlyTheRowsItIsGiven() {
        XCTAssertEqual(SFTPSelection.all(order), Set(order))
        XCTAssertEqual(SFTPSelection.all([]), [], "an empty listing selects nothing")
    }
}
