import XCTest
@testable import KRemoteCore

/// Cancelling an editor must not leave a record behind.
///
/// Reported: "Add as a server" opened the New Connection screen, and Cancel still left
/// the created record in place. Every cancelled dialog that accumulates an empty row is
/// the same bug, so the rule is pinned case by case.
final class ProvisionalNodesTests: XCTestCase {

    func testCancellingANewNodeRemovesIt() {
        var nodes = ProvisionalNodes()
        let id = UUID()
        nodes.begin(id)

        XCTAssertTrue(nodes.cancel(id), "a node created here and never saved must be removed")
        XCTAssertFalse(nodes.isProvisional(id))
    }

    /// The reported case exactly: create, open the editor, cancel.
    func testAddAsServerThenCancel() {
        var nodes = ProvisionalNodes()
        let id = UUID()
        nodes.begin(id)
        XCTAssertTrue(nodes.cancel(id))
        XCTAssertEqual(nodes.count, 0, "nothing may be left waiting to be saved")
    }

    /// Saving makes the node real; a later cancel must not delete it.
    func testCommittedNodeSurvivesACancel() {
        var nodes = ProvisionalNodes()
        let id = UUID()
        nodes.begin(id)
        nodes.commit(id)

        XCTAssertFalse(nodes.cancel(id), "a saved node is not provisional")
        XCTAssertFalse(nodes.isProvisional(id))
    }

    /// Editing a connection that was already in the tree and dismissing the editor leaves
    /// that connection alone: the user declined a change, not the connection.
    func testCancellingAnEditToAnExistingNodeRemovesNothing() {
        var nodes = ProvisionalNodes()
        let existing = UUID()

        XCTAssertFalse(nodes.cancel(existing))
        XCTAssertEqual(nodes.count, 0)
    }

    /// Cancel runs from the button and again from the sheet's dismiss handler; the second
    /// call must not report a second removal.
    func testCancelIsIdempotent() {
        var nodes = ProvisionalNodes()
        let id = UUID()
        nodes.begin(id)

        XCTAssertTrue(nodes.cancel(id))
        XCTAssertFalse(nodes.cancel(id), "already discarded")
    }

    /// Two editors open on two new nodes: cancelling one leaves the other alone.
    func testOnlyTheCancelledNodeIsReported() {
        var nodes = ProvisionalNodes()
        let a = UUID(), b = UUID()
        nodes.begin(a)
        nodes.begin(b)

        XCTAssertTrue(nodes.cancel(a))
        XCTAssertTrue(nodes.isProvisional(b), "cancelling a must not touch b")
        XCTAssertTrue(nodes.cancel(b), "b is still provisional and must be removable")
    }

    func testCountTracksOnlyUnsavedNodes() {
        var nodes = ProvisionalNodes()
        let a = UUID(), b = UUID(), c = UUID()
        nodes.begin(a)
        nodes.begin(b)
        nodes.begin(c)
        nodes.commit(b)

        XCTAssertEqual(nodes.count, 2)
    }
}
