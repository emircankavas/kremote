import XCTest
@testable import KRemoteCore

/// The tab strip shrank into a fixed 180 pt per tab with a 720 pt cap, so the
/// sixth session was unreachable behind a horizontal scroll. These pin the
/// browser arithmetic that replaced it.
final class TabStripLayoutTests: XCTestCase {

    func testFewTabsAreNotStretchedPastTheCap() {
        let layout = TabStripLayout(count: 2, available: 1200)
        XCTAssertEqual(layout.visibleCount, 2)
        XCTAssertEqual(layout.tabWidth, TabStripLayout.maxWidth)
        XCTAssertEqual(layout.overflowCount, 0)
    }

    func testTabsShrinkTogether() {
        let two = TabStripLayout(count: 2, available: 600)
        let four = TabStripLayout(count: 4, available: 600)
        XCTAssertGreaterThan(two.tabWidth, four.tabWidth)
        XCTAssertEqual(four.visibleCount, 4)
    }

    func testTenTabsAllFitInAWideWindow() {
        let layout = TabStripLayout(count: 10, available: 1200)
        XCTAssertEqual(layout.visibleCount, 10)
        XCTAssertEqual(layout.overflowCount, 0)
        XCTAssertLessThanOrEqual(layout.tabWidth, TabStripLayout.maxWidth)
        // 10 tabs at the floor plus 9 gaps still fit in 1200.
        XCTAssertGreaterThanOrEqual(layout.tabWidth, TabStripLayout.minWidth)
    }

    func testOverflowAppearsOnlyWhenTheFloorNoLongerFits() {
        // 20 tabs at 96 pt need ~1958 pt.
        let layout = TabStripLayout(count: 20, available: 900)
        XCTAssertLessThan(layout.visibleCount, 20)
        XCTAssertGreaterThan(layout.overflowCount, 0)
        XCTAssertGreaterThanOrEqual(layout.tabWidth, TabStripLayout.minWidth)

        // The visible ones must actually fit, and one more would not.
        let used = CGFloat(layout.visibleCount) * layout.tabWidth
            + CGFloat(layout.visibleCount - 1) * TabStripLayout.gap
        XCTAssertLessThanOrEqual(used, 900)
        let oneMore = used + TabStripLayout.gap + TabStripLayout.minWidth
        XCTAssertGreaterThan(oneMore, 900)
    }

    func testNarrowStripHidesTitles() {
        let layout = TabStripLayout(count: 8, available: 700)
        XCTAssertTrue(layout.showsOnlyIcon)
        let wide = TabStripLayout(count: 2, available: 700)
        XCTAssertFalse(wide.showsOnlyIcon)
    }

    func testNoSpaceMeansNoTabs() {
        let layout = TabStripLayout(count: 3, available: 0)
        XCTAssertEqual(layout.visibleCount, 0)
        XCTAssertEqual(layout.overflowCount, 3)
        XCTAssertEqual(layout.tabWidth, 0)
    }

    // MARK: - Reordering

    func testMoveToTheRightLandsAfterTheTarget() {
        let moved = TabOrdering.move(["a", "b", "c", "d"], from: 0, to: 2)
        XCTAssertEqual(moved, ["b", "c", "a", "d"])
    }

    func testMoveToTheLeft() {
        XCTAssertEqual(TabOrdering.move(["a", "b", "c", "d"], from: 3, to: 1), ["a", "d", "b", "c"])
    }

    func testMovingOntoItselfChangesNothing() {
        XCTAssertEqual(TabOrdering.move(["a", "b", "c"], from: 1, to: 1), ["a", "b", "c"])
    }

    func testOutOfRangeIndexIsIgnored() {
        XCTAssertEqual(TabOrdering.move(["a", "b"], from: 5, to: 0), ["a", "b"])
        XCTAssertEqual(TabOrdering.move(["a", "b"], from: 0, to: 9), ["b", "a"])
    }
}
