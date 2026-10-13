import XCTest
@testable import KRemoteCore

final class SearchTests: XCTestCase {

    private func sample() -> [ConnectionNode] {
        [
            .folder("Production", [
                .connection("web-01", host: "10.0.0.11", username: "deploy", protocolName: "SSH2"),
                .folder("Databases", [
                    .connection("pg-primary", host: "10.0.0.21", username: "postgres", protocolName: "SSH2"),
                ]),
            ]),
            .folder("Lab", [
                .connection("router", host: "192.168.1.1", username: "admin", protocolName: "Telnet"),
            ]),
        ]
    }

    func testEmptyQueryReturnsNothing() {
        XCTAssertTrue(ConnectionNode.search("", in: sample()).isEmpty)
        XCTAssertTrue(ConnectionNode.search("   ", in: sample()).isEmpty)
    }

    func testMatchesByName() {
        let hits = ConnectionNode.search("pg", in: sample())
        XCTAssertEqual(hits.map(\.name), ["pg-primary"])
    }

    func testMatchesByHostAndIsCaseInsensitive() {
        XCTAssertEqual(ConnectionNode.search("10.0.0.21", in: sample()).map(\.name), ["pg-primary"])
        XCTAssertEqual(ConnectionNode.search("WEB-01", in: sample()).map(\.name), ["web-01"])
    }

    func testMatchesByUsernameAcrossTree() {
        let hits = ConnectionNode.search("deploy", in: sample())
        XCTAssertEqual(hits.map(\.name), ["web-01"])
    }

    func testMatchesByProtocol() {
        let hits = ConnectionNode.search("telnet", in: sample())
        XCTAssertEqual(hits.map(\.name), ["router"])
    }

    func testMatchesFoldersToo() {
        let hits = ConnectionNode.search("databases", in: sample())
        XCTAssertEqual(hits.map(\.name), ["Databases"])
    }

    func testNoMatchesReturnsEmpty() {
        XCTAssertTrue(ConnectionNode.search("nothing-here", in: sample()).isEmpty)
    }
}
