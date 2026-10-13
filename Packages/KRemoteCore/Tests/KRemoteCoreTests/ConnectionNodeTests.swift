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
        let folder = ConnectionNode(kind: .folder, name: "Prod", port: 2222, username: "deploy")
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

    func testIdentityFileAndRemoteCommandInherit() {
        let root = ConnectionNode(kind: .folder, name: "Corp", identityFile: "~/.ssh/id_corp")
        let middle = ConnectionNode(kind: .folder, name: "Team", remoteCommand: "tmux attach")
        let leaf = ConnectionNode(kind: .connection, name: "host", host: "h", identityFile: "/override/id")
        middle.children = [leaf]
        root.children = [middle]

        let effective = ConnectionNode.effective(for: leaf.id, in: [root])
        XCTAssertEqual(effective?.identityFile, "/override/id", "leaf overrides the folder's key")
        XCTAssertEqual(effective?.remoteCommand, "tmux attach", "command inherited from the middle folder")
    }

    func testFolderItselfResolvesToInheritedDefaults() {
        let folder = ConnectionNode(kind: .folder, name: "Empty")
        let effective = ConnectionNode.effective(for: folder.id, in: [folder])
        XCTAssertEqual(effective?.port, 22)
        XCTAssertEqual(effective?.protocolName, "SSH")
    }

    func testPortDefaultsToProtocolWhenNothingSetsIt() {
        // A folder carrying only a protocol should give its connections the
        // protocol's own default port, not SSH's 22.
        let folder = ConnectionNode(kind: .folder, name: "Web", protocolName: "HTTPS")
        let leaf = ConnectionNode(kind: .connection, name: "ilot", host: "10.0.0.9")
        folder.children = [leaf]

        let effective = ConnectionNode.effective(for: leaf.id, in: [folder])
        XCTAssertEqual(effective?.protocolName, "HTTPS")
        XCTAssertEqual(effective?.port, 443, "HTTPS should default to 443, not 22")
    }

    func testExplicitPortStillWins() {
        let folder = ConnectionNode(kind: .folder, name: "Web", port: 8443, protocolName: "HTTPS")
        let leaf = ConnectionNode(kind: .connection, name: "ilot", host: "h")
        folder.children = [leaf]
        XCTAssertEqual(ConnectionNode.effective(for: leaf.id, in: [folder])?.port, 8443)
    }

    func testLeafPortOverridesProtocolDefault() {
        let leaf = ConnectionNode(kind: .connection, name: "x", host: "h", port: 2222, protocolName: "HTTPS")
        XCTAssertEqual(ConnectionNode.effective(for: leaf.id, in: [leaf])?.port, 2222)
    }

    func testSupportsSSH() {
        XCTAssertTrue(ConnectionNode(kind: .connection, name: "a", protocolName: "SSH2").supportsSSH)
        XCTAssertTrue(ConnectionNode(kind: .connection, name: "b", protocolName: "").supportsSSH)
        XCTAssertFalse(ConnectionNode(kind: .connection, name: "c", protocolName: "RDP").supportsSSH)
        XCTAssertFalse(ConnectionNode(kind: .connection, name: "d", protocolName: "HTTPS").supportsSSH)
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
