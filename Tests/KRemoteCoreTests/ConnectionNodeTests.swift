import XCTest
@testable import KRemoteCore

final class ConnectionNodeTests: XCTestCase {

    // MARK: - Inheritance

    func testLeafInheritsFromFolder() {
        let folder = ConnectionNode(kind: .folder, name: "Prod", username: "deploy", protocolName: "SSH")
        let leaf = ConnectionNode(kind: .connection, name: "web-01", host: "10.0.0.11")
        folder.children = [leaf]

        let effective = ConnectionNode.effective(for: leaf.id, in: [folder])
        XCTAssertEqual(effective?.host, "10.0.0.11")
        XCTAssertEqual(effective?.username, "deploy", "username should come from the folder")
        XCTAssertEqual(effective?.protocolName, "SSH")
        XCTAssertEqual(effective?.port, 22, "port falls back to the protocol default")
    }

    func testLeafOverridesFolder() {
        let folder = ConnectionNode(kind: .folder, name: "Prod", username: "deploy", port: 2222)
        let leaf = ConnectionNode(
            kind: .connection,
            name: "web-01",
            host: "10.0.0.11",
            port: 22,
            username: "root"
        )
        folder.children = [leaf]

        let effective = ConnectionNode.effective(for: leaf.id, in: [folder])
        XCTAssertEqual(effective?.username, "root", "direct value wins over the folder's")
        XCTAssertEqual(effective?.port, 22)
    }

    func testNestedFoldersInheritThroughLevels() {
        let root = ConnectionNode(kind: .folder, name: "Prod", username: "svc", password: "secret")
        let middle = ConnectionNode(kind: .folder, name: "Databases")
        let leaf = ConnectionNode(kind: .connection, name: "pg", host: "10.0.0.21")
        middle.children = [leaf]
        root.children = [middle]

        let effective = ConnectionNode.effective(for: leaf.id, in: [root])
        XCTAssertEqual(effective?.username, "svc", "inherited across two folder levels")
        XCTAssertEqual(effective?.password, "secret")
    }

    func testFolderItselfResolvesToInheritedDefaults() {
        let folder = ConnectionNode(kind: .folder, name: "Empty")
        let effective = ConnectionNode.effective(for: folder.id, in: [folder])
        XCTAssertEqual(effective, .default)
    }

    // MARK: - Tree operations

    func testFindAndParentID() {
        let folder = ConnectionNode(kind: .folder, name: "Prod")
        let leaf = ConnectionNode(kind: .connection, name: "web-01", host: "h")
        folder.children = [leaf]
        let roots = [folder]

        XCTAssertNotNil(ConnectionNode.find(leaf.id, in: roots))
        XCTAssertEqual(ConnectionNode.parentID(of: leaf.id, in: roots), folder.id)
        XCTAssertNil(ConnectionNode.parentID(of: folder.id, in: roots))
    }

    func testRemoveReturnsRemovedSubtree() {
        let folder = ConnectionNode(kind: .folder, name: "Prod")
        let leaf = ConnectionNode(kind: .connection, name: "web-01", host: "h")
        folder.children = [leaf]
        var roots = [folder]

        let removed = ConnectionNode.remove(folder.id, from: &roots)
        XCTAssertEqual(removed?.children.count, 1)
        XCTAssertTrue(roots.isEmpty)
        XCTAssertNil(ConnectionNode.find(leaf.id, in: roots))
    }

    func testAllNodesIsDepthFirst() {
        let leaf = ConnectionNode(kind: .connection, name: "leaf", host: "h")
        let inner = ConnectionNode(kind: .folder, name: "inner", children: [leaf])
        let root = ConnectionNode(kind: .folder, name: "root", children: [inner])

        let names = ConnectionNode.allNodes(in: [root]).map(\.name)
        XCTAssertEqual(names, ["root", "inner", "leaf"])
    }

    // MARK: - Persistence

    func testCodableRoundTripPreservesTree() throws {
        let roots = ConnectionNode.sample
        let data = try JSONEncoder().encode(roots)
        let decoded = try JSONDecoder().decode([ConnectionNode].self, from: data)

        XCTAssertEqual(decoded.count, roots.count)
        XCTAssertEqual(ConnectionNode.allNodes(in: decoded).count, ConnectionNode.allNodes(in: roots).count)
        XCTAssertEqual(decoded[0].children[0].name, "web-01")
        XCTAssertEqual(decoded[0].children[0].host, "10.0.0.11")
    }

    func testPasswordIsNeverEncoded() throws {
        let leaf = ConnectionNode(kind: .connection, name: "web", host: "h", password: "hunter2")
        let data = try JSONEncoder().encode([leaf])
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(json.contains("hunter2"), "password must not reach the JSON tree")
        XCTAssertFalse(json.lowercased().contains("password"), "no password key at all")
    }

    func testNodeStoreRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kremote-test-\(UUID().uuidString)")
            .appendingPathComponent("tree.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = NodeStore(fileURL: url)
        XCTAssertNil(try store.load(), "missing file loads as nil")

        try store.save(ConnectionNode.sample)
        let loaded = try store.load()
        XCTAssertEqual(loaded?.count, ConnectionNode.sample.count)
        XCTAssertEqual(loaded?[1].name, "Lab")
    }

    // MARK: - Secret store

    func testInMemorySecretStore() throws {
        let store = InMemorySecretStore()
        let id = UUID()

        XCTAssertNil(try store.secret(for: id))
        try store.setSecret("s3cret", for: id)
        XCTAssertEqual(try store.secret(for: id), "s3cret")

        try store.setSecret("", for: id)
        XCTAssertNil(try store.secret(for: id), "empty secret clears the item")

        try store.setSecret("again", for: id)
        try store.removeSecret(for: id)
        XCTAssertNil(try store.secret(for: id))
    }
}
