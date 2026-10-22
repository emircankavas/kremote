import XCTest
@testable import KRemoteCore

/// The second line of a sidebar row.
///
/// Reported: the row showed the tree position instead of the server's address. The address
/// is what someone scanning a list of servers is looking for, so it leads — and the port is
/// printed only when it is not the default, because `22` on every SSH row is noise.
final class ConnectionSubtitleTests: XCTestCase {

    func testHostOnly() {
        XCTAssertEqual(
            ConnectionSubtitle.address(host: "10.0.31.11", username: "", port: 22, protocolName: "SSH"),
            "10.0.31.11"
        )
    }

    func testUsernameIsPrefixed() {
        XCTAssertEqual(
            ConnectionSubtitle.address(host: "10.0.31.11", username: "root", port: 22, protocolName: "SSH"),
            "root@10.0.31.11"
        )
    }

    /// The default port is not printed: every SSH row saying `:22` is noise.
    func testDefaultPortIsHidden() {
        XCTAssertEqual(
            ConnectionSubtitle.address(host: "10.0.31.11", username: "", port: 22, protocolName: "SSH2"),
            "10.0.31.11"
        )
    }

    func testNonDefaultPortIsShown() {
        XCTAssertEqual(
            ConnectionSubtitle.address(host: "10.0.31.11", username: "", port: 2222, protocolName: "SSH"),
            "10.0.31.11:2222"
        )
    }

    /// RDP's default is 3389, not 22: the same rule with a different threshold.
    func testRDPDefaultPortIsHidden() {
        XCTAssertEqual(
            ConnectionSubtitle.address(host: "192.168.1.137", username: "admin", port: 3389, protocolName: "RDP"),
            "admin@192.168.1.137"
        )
    }

    func testRDPNonDefaultPortIsShown() {
        XCTAssertEqual(
            ConnectionSubtitle.address(host: "192.168.1.137", username: "", port: 13389, protocolName: "RDP"),
            "192.168.1.137:13389"
        )
    }

    /// An SSH connection explicitly on 3389 shows it: it is not SSH's default, and hiding
    /// it would misrepresent where the connection goes.
    func testPortThatIsNotThisProtocolsDefaultIsShown() {
        XCTAssertEqual(
            ConnectionSubtitle.address(host: "host", username: "", port: 3389, protocolName: "SSH"),
            "host:3389"
        )
    }

    func testAnUnconfiguredConnectionHasNoAddress() {
        XCTAssertNil(ConnectionSubtitle.address(host: "", username: "root", port: 22, protocolName: "SSH"))
        XCTAssertNil(ConnectionSubtitle.address(host: "   ", username: "", port: 22, protocolName: "SSH"))
    }

    /// An unset port (0) prints nothing rather than ":0".
    func testUnsetPortIsNotPrinted() {
        XCTAssertEqual(
            ConnectionSubtitle.address(host: "host", username: "", port: 0, protocolName: "SSH"),
            "host"
        )
    }

    /// An empty protocol name resolves as SSH, the same way a node resolves itself.
    func testEmptyProtocolTreatedAsSSH() {
        XCTAssertEqual(
            ConnectionSubtitle.address(host: "host", username: "", port: 22, protocolName: ""),
            "host"
        )
    }

    func testPathIsAppendedToTheAddress() {
        XCTAssertEqual(
            ConnectionSubtitle.address("10.0.31.11", path: ["Production", "Linux"]),
            "10.0.31.11 · Production ▸ Linux"
        )
    }

    func testNoPathLeavesTheAddressAlone() {
        XCTAssertEqual(ConnectionSubtitle.address("10.0.31.11", path: []), "10.0.31.11")
    }
}
