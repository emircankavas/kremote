import XCTest
@testable import KRemoteCore

final class PaneTilingTests: XCTestCase {

    func testLayoutShape() {
        XCTAssertEqual(PaneLayout(count: 1).columns, 1)
        XCTAssertEqual(PaneLayout(count: 1).rows, 1)
        XCTAssertEqual(PaneLayout(count: 2).columns, 2)
        XCTAssertEqual(PaneLayout(count: 2).rows, 1)
        XCTAssertEqual(PaneLayout(count: 4).columns, 2)
        XCTAssertEqual(PaneLayout(count: 4).rows, 2)
        XCTAssertTrue(PaneLayout(count: 3).isSplit)
        XCTAssertFalse(PaneLayout(count: 1).isSplit)
    }

    func testLayoutClampsCount() {
        XCTAssertEqual(PaneLayout(count: 0).count, 1)
        XCTAssertEqual(PaneLayout(count: 9).count, 4)
    }

    func testReconcileFillsEmptyTilesInOrder() {
        let a = UUID(), b = UUID(), c = UUID()
        let tiles = PaneTiling.reconcile(existing: [], sessionIDs: [a, b, c], paneCount: 2)
        XCTAssertEqual(tiles.count, 2)
        XCTAssertEqual(tiles[0], a)
        XCTAssertEqual(tiles[1], b)
    }

    func testReconcileDropsClosedSessions() {
        let a = UUID(), b = UUID()
        // b was closed; only a remains.
        let tiles = PaneTiling.reconcile(existing: [a, b], sessionIDs: [a], paneCount: 2)
        XCTAssertEqual(tiles[0], a)
        XCTAssertEqual(tiles[1], nil)
    }

    func testReconcilePreservesValidAssignments() {
        let a = UUID(), b = UUID(), c = UUID()
        // b is in tile 1 explicitly; c is new and should fill nothing (tiles full).
        let tiles = PaneTiling.reconcile(existing: [a, b], sessionIDs: [a, b, c], paneCount: 2)
        XCTAssertEqual(tiles, [a, b])
        // c stays untitled (still an open session, just not shown).
        XCTAssertNil(PaneTiling.tile(of: c, in: tiles))
    }

    func testReconcileTrimsWhenPaneCountShrinks() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let tiles = PaneTiling.reconcile(existing: [a, b, c, d], sessionIDs: [a, b, c, d], paneCount: 2)
        XCTAssertEqual(tiles, [a, b])
    }

    func testReconcileBackfillsWhenPaneCountGrows() {
        let a = UUID(), b = UUID(), c = UUID()
        let tiles = PaneTiling.reconcile(existing: [a], sessionIDs: [a, b, c], paneCount: 3)
        XCTAssertEqual(tiles[0], a)
        // b and c fill the new tiles in order.
        XCTAssertEqual(tiles[1], b)
        XCTAssertEqual(tiles[2], c)
    }

    func testReconcileRemovesDuplicates() {
        let a = UUID()
        let tiles = PaneTiling.reconcile(existing: [a, a], sessionIDs: [a], paneCount: 2)
        XCTAssertEqual(tiles[0], a)
        XCTAssertNil(tiles[1], "the same session must not occupy two tiles")
    }

    func testPlaceFillsFirstEmptyThenFocused() {
        let a = UUID(), b = UUID(), c = UUID()
        var tiles: [UUID?] = [a, nil]
        PaneTiling.place(session: b, in: &tiles, focusedTile: 0)
        XCTAssertEqual(tiles, [a, b], "empty tile is filled first")

        PaneTiling.place(session: c, in: &tiles, focusedTile: 0)
        XCTAssertEqual(tiles[0], c, "when full, the focused tile is replaced")
        XCTAssertEqual(tiles[1], b)
    }

    func testTiledSessionsInOrder() {
        let a = UUID(), b = UUID(), c = UUID()
        let order = PaneTiling.tiledSessions(in: [b, nil, a], sessionIDs: [a, b, c])
        XCTAssertEqual(order, [b, a])
    }
}
