import XCTest
@testable import KRemoteCore

/// Guards the on-disk format against the failure that broke a real 0.1.0 install:
/// adding a property (`identityFile`) made old files undecodable with
/// `keyNotFound`. Old files must keep loading; unknown future keys must be ignored.
final class MigrationTests: XCTestCase {

    /// Exactly what version 0.1.0 wrote: no `identityFile` / `remoteCommand`.
    private let legacyJSON = """
    {
      "version": 1,
      "roots": [
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "kind": "folder",
          "name": "Prod",
          "host": "",
          "port": 0,
          "username": "svc",
          "protocolName": "SSH2",
          "children": [
            {
              "id": "22222222-2222-2222-2222-222222222222",
              "kind": "connection",
              "name": "web",
              "host": "10.0.0.1",
              "port": 22,
              "username": "deploy",
              "protocolName": "SSH2",
              "children": []
            }
          ]
        }
      ]
    }
    """

    func testDecodesLegacyFileWithoutNewKeys() throws {
        let roots = try decodeRoots(fromLegacy: legacyJSON)
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots[0].name, "Prod")
        let leaf = try XCTUnwrap(roots[0].children.first)
        XCTAssertEqual(leaf.host, "10.0.0.1")
        // New fields default cleanly instead of throwing.
        XCTAssertEqual(leaf.identityFile, "")
        XCTAssertEqual(leaf.remoteCommand, "")
        XCTAssertEqual(leaf.password, "", "password never comes from the file")
    }

    func testDecodesBareMinimumNode() throws {
        // Only id/kind/name present — every other field must default.
        let json = """
        { "version": 1, "roots": [
          { "id": "33333333-3333-3333-3333-333333333333", "kind": "connection", "name": "x" }
        ] }
        """
        let roots = try decodeRoots(fromLegacy: json)
        let node = try XCTUnwrap(roots.first)
        XCTAssertEqual(node.host, "")
        XCTAssertEqual(node.port, 0)
        XCTAssertEqual(node.children, [])
    }

    func testIgnoresUnknownFutureKeys() throws {
        let json = """
        { "version": 99, "roots": [
          { "id": "44444444-4444-4444-4444-444444444444", "kind": "connection", "name": "x",
            "somethingNew": true, "identityFile": "/k" }
        ] }
        """
        let roots = try decodeRoots(fromLegacy: json)
        XCTAssertEqual(roots.first?.identityFile, "/k")
    }

    func testFullRoundTripStillWorks() throws {
        let original = ConnectionNode.sample
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([ConnectionNode].self, from: data)
        XCTAssertEqual(
            ConnectionNode.allNodes(in: decoded).map(\.name),
            ConnectionNode.allNodes(in: original).map(\.name)
        )
    }

    private func decodeRoots(fromLegacy json: String) throws -> [ConnectionNode] {
        struct Envelope: Decodable { var roots: [ConnectionNode] }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(json.utf8))
        return envelope.roots
    }
}
