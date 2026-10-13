import XCTest
@testable import KRemoteCore

final class MoveTests: XCTestCase {

    private func tree() -> [ConnectionNode] {
        [
            .folder("Prod", [
                .connection("web", host: "10.0.0.1"),
                .folder("Inner", []),
            ]),
            .folder("Lab", [
                .connection("router", host: "192.168.1.1"),
            ]),
        ]
    }

    private func names(_ roots: [ConnectionNode]) -> [String] {
        ConnectionNode.allNodes(in: roots).map(\.name)
    }

    func testMoveLeafIntoFolder() throws {
        var roots = tree()
        let web = try XCTUnwrap(ConnectionNode.allNodes(in: roots).first { $0.name == "web" })
        let lab = try XCTUnwrap(roots.first { $0.name == "Lab" })

        XCTAssertTrue(ConnectionNode.move(web.id, to: lab.id, in: &roots))

        let labChildren = try XCTUnwrap(roots.first { $0.name == "Lab" }).children.map(\.name)
        XCTAssertTrue(labChildren.contains("web"))
        XCTAssertFalse(try XCTUnwrap(roots.first { $0.name == "Prod" }).children.contains { $0.name == "web" })
        // No duplicates.
        XCTAssertEqual(names(roots).filter { $0 == "web" }.count, 1)
    }

    func testMoveNodeToRoot() throws {
        var roots = tree()
        let web = try XCTUnwrap(ConnectionNode.allNodes(in: roots).first { $0.name == "web" })

        XCTAssertTrue(ConnectionNode.move(web.id, to: nil, in: &roots))
        XCTAssertTrue(roots.contains { $0.name == "web" })
    }

    func testRefusesMoveIntoOwnDescendant() throws {
        var roots = tree()
        let prod = try XCTUnwrap(roots.first { $0.name == "Prod" })
        let inner = try XCTUnwrap(ConnectionNode.allNodes(in: roots).first { $0.name == "Inner" })

        // Prod into its own child Inner must be refused (would detach the subtree).
        XCTAssertFalse(ConnectionNode.move(prod.id, to: inner.id, in: &roots))
        XCTAssertEqual(names(roots).sorted(), ["Inner", "Lab", "Prod", "router", "web"])
    }

    func testRefusesMoveIntoItself() throws {
        var roots = tree()
        let prod = try XCTUnwrap(roots.first { $0.name == "Prod" })
        XCTAssertFalse(ConnectionNode.move(prod.id, to: prod.id, in: &roots))
    }

    func testRefusesDroppingIntoConnection() throws {
        var roots = tree()
        let web = try XCTUnwrap(ConnectionNode.allNodes(in: roots).first { $0.name == "web" })
        let router = try XCTUnwrap(ConnectionNode.allNodes(in: roots).first { $0.name == "router" })

        // A leaf cannot hold children.
        XCTAssertFalse(ConnectionNode.move(web.id, to: router.id, in: &roots))
    }

    func testContainsDetectsAncestry() throws {
        let roots = tree()
        let prod = try XCTUnwrap(roots.first { $0.name == "Prod" })
        let inner = try XCTUnwrap(ConnectionNode.allNodes(in: roots).first { $0.name == "Inner" })

        XCTAssertTrue(ConnectionNode.contains(prod.id, inner.id, in: roots))
        XCTAssertTrue(ConnectionNode.contains(prod.id, prod.id, in: roots))
        XCTAssertFalse(ConnectionNode.contains(inner.id, prod.id, in: roots))
    }
}
