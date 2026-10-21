import XCTest
@testable import KRemoteCore

/// Parsing what was typed into the search box as a connection target.
///
/// This decides where a connection goes. A parser that silently mis-splits
/// `user@host:port` connects somewhere the user did not ask for, so every shape is
/// pinned — including the ones that must be *refused*, because a "connect to…" row for a
/// search phrase would be noise.
final class AdHocTargetTests: XCTestCase {

    func testPlainHost() throws {
        let target = try XCTUnwrap(AdHocTarget.parse("10.0.31.11"))
        XCTAssertEqual(target.host, "10.0.31.11")
        XCTAssertEqual(target.username, "")
        XCTAssertNil(target.port)
    }

    func testHostnameWithDotsAndDashes() throws {
        let target = try XCTUnwrap(AdHocTarget.parse("prod-web-01.kavas.dev"))
        XCTAssertEqual(target.host, "prod-web-01.kavas.dev")
    }

    func testHostWithPort() throws {
        let target = try XCTUnwrap(AdHocTarget.parse("10.0.31.11:2222"))
        XCTAssertEqual(target.host, "10.0.31.11")
        XCTAssertEqual(target.port, 2222)
    }

    func testUserAtHost() throws {
        let target = try XCTUnwrap(AdHocTarget.parse("root@10.0.31.11"))
        XCTAssertEqual(target.username, "root")
        XCTAssertEqual(target.host, "10.0.31.11")
        XCTAssertNil(target.port)
    }

    func testUserAtHostWithPort() throws {
        let target = try XCTUnwrap(AdHocTarget.parse("admin@server.local:2200"))
        XCTAssertEqual(target.username, "admin")
        XCTAssertEqual(target.host, "server.local")
        XCTAssertEqual(target.port, 2200)
    }

    /// A bracketed IPv6 literal carries colons of its own, so the port is only what
    /// follows the closing bracket.
    func testBracketedIPv6WithPort() throws {
        let target = try XCTUnwrap(AdHocTarget.parse("[2001:db8::1]:22"))
        XCTAssertEqual(target.host, "2001:db8::1")
        XCTAssertEqual(target.port, 22)
    }

    func testBracketedIPv6WithoutPort() throws {
        let target = try XCTUnwrap(AdHocTarget.parse("[::1]"))
        XCTAssertEqual(target.host, "::1")
        XCTAssertNil(target.port)
    }

    /// An unbracketed IPv6 address has no port. Splitting on the last colon would turn
    /// `::1` into host `::` port 1.
    func testUnbracketedIPv6IsNotSplit() throws {
        let target = try XCTUnwrap(AdHocTarget.parse("2001:db8::1"))
        XCTAssertEqual(target.host, "2001:db8::1")
        XCTAssertNil(target.port)
    }

    // MARK: - What must be refused

    /// A sentence is a search phrase, not a host.
    func testSpacesAreRefused() {
        XCTAssertNil(AdHocTarget.parse("my server"))
        XCTAssertNil(AdHocTarget.parse("connect to 10.0.0.1"))
    }

    func testEmptyIsRefused() {
        XCTAssertNil(AdHocTarget.parse(""))
        XCTAssertNil(AdHocTarget.parse("   "))
    }

    func testInvalidPortsAreRefused() {
        XCTAssertNil(AdHocTarget.parse("host:0"), "port 0 is not reachable")
        XCTAssertNil(AdHocTarget.parse("host:99999"), "out of range")
        XCTAssertNil(AdHocTarget.parse("host:abc"), "not a number")
        XCTAssertNil(AdHocTarget.parse("host:"), "empty port")
    }

    func testDanglingUserOrHostIsRefused() {
        XCTAssertNil(AdHocTarget.parse("@host"), "empty username")
        XCTAssertNil(AdHocTarget.parse("user@"), "empty host")
    }

    /// Characters no hostname or address can hold: a typed sentence fragment, or a
    /// search for something like `nginx.conf` — which should search, not connect.
    func testCharactersOutsideAHostAreRefused() {
        XCTAssertNil(AdHocTarget.parse("host/path"))
        XCTAssertNil(AdHocTarget.parse("host name"))
        XCTAssertNil(AdHocTarget.parse("<script>"))
    }

    func testBarePunctuationIsRefused() {
        XCTAssertNil(AdHocTarget.parse("."))
        XCTAssertNil(AdHocTarget.parse("-"))
        XCTAssertNil(AdHocTarget.parse(":"))
    }

    /// `host:22:33` is not a host with a port; refusing beats guessing.
    func testTwoColonsWithoutBracketsIsRefused() {
        // Two colons looks like IPv6, which is accepted — but `host:22:33` is not a
        // valid literal, and the honest answer is to let it be an IPv6 attempt rather
        // than silently picking a port.
        let parsed = AdHocTarget.parse("host:22:33")
        XCTAssertNil(parsed?.port, "must not invent a port from an ambiguous string")
    }

    // MARK: - Already in the tree

    private func savedNode(name: String, host: String, port: Int = 0, protocol protocolName: String = "SSH2") -> ConnectionNode {
        ConnectionNode(kind: .connection, name: name, host: host, port: port, protocolName: protocolName)
    }

    /// The reported bug: `10.0.31.11` was saved as *qs-ansible*, and the search offered to
    /// connect to the address anyway. Taking that would discard the saved name, its
    /// folder, and the credentials inherited from that folder.
    func testSavedHostSuppressesTheAdHocOffer() throws {
        let roots = [savedNode(name: "qs-ansible", host: "10.0.31.11")]
        let target = try XCTUnwrap(AdHocTarget.parse("10.0.31.11"))
        XCTAssertEqual(AdHocTarget.existingMatches(for: target, in: roots).map(\.name), ["qs-ansible"])
    }

    /// Case and surrounding whitespace must not defeat the match: a hostname is not
    /// case-sensitive.
    func testMatchIsCaseInsensitive() throws {
        let roots = [savedNode(name: "prod", host: "Prod-Web-01.kavas.dev")]
        let target = try XCTUnwrap(AdHocTarget.parse("prod-web-01.kavas.dev"))
        XCTAssertEqual(AdHocTarget.existingMatches(for: target, in: roots).count, 1)
    }

    /// A different address is a different host, even if the name looks similar.
    func testDifferentHostDoesNotMatch() throws {
        let roots = [savedNode(name: "qs-ansible", host: "10.0.31.11")]
        let target = try XCTUnwrap(AdHocTarget.parse("10.0.31.12"))
        XCTAssertTrue(AdHocTarget.existingMatches(for: target, in: roots).isEmpty)
    }

    /// A saved host on another port is a different endpoint, so the ad-hoc row stays.
    func testPortNarrowsTheMatch() throws {
        let roots = [savedNode(name: "qs-ansible", host: "10.0.31.11", port: 22)]
        let other = try XCTUnwrap(AdHocTarget.parse("10.0.31.11:2222"))
        XCTAssertTrue(AdHocTarget.existingMatches(for: other, in: roots).isEmpty)

        let same = try XCTUnwrap(AdHocTarget.parse("10.0.31.11:22"))
        XCTAssertEqual(AdHocTarget.existingMatches(for: same, in: roots).count, 1)
    }

    /// Typing just the host matches a saved entry that has an explicit port: the user did
    /// not ask for a specific port, so any saved port is that host.
    func testNoPortMatchesAnySavedPort() throws {
        let roots = [savedNode(name: "qs-ansible", host: "10.0.31.11", port: 2222)]
        let target = try XCTUnwrap(AdHocTarget.parse("10.0.31.11"))
        XCTAssertEqual(AdHocTarget.existingMatches(for: target, in: roots).count, 1)
    }

    /// Folders are not connections; a folder that happens to carry an address must not
    /// suppress the row.
    func testFoldersDoNotMatch() throws {
        let folder = ConnectionNode(kind: .folder, name: "10.0.31.11", host: "10.0.31.11")
        let target = try XCTUnwrap(AdHocTarget.parse("10.0.31.11"))
        XCTAssertTrue(AdHocTarget.existingMatches(for: target, in: [folder]).isEmpty)
    }

    /// The match is found wherever the node sits, not only at the root.
    func testMatchInsideAFolder() throws {
        let nested = ConnectionNode(
            kind: .folder,
            name: "Production",
            children: [savedNode(name: "qs-ansible", host: "10.0.31.11")]
        )
        let target = try XCTUnwrap(AdHocTarget.parse("10.0.31.11"))
        XCTAssertEqual(AdHocTarget.existingMatches(for: target, in: [nested]).count, 1)
    }

    // MARK: - Node construction

    func testNodeUsesTheProtocolDefaultPortWhenNoneGiven() {
        let target = AdHocTarget.parse("10.0.0.5")!
        let ssh = AdHocConnection.makeNode(for: target, protocol: .ssh)
        let rdp = AdHocConnection.makeNode(for: target, protocol: .rdp)

        XCTAssertEqual(ssh.port, 22)
        XCTAssertEqual(rdp.port, 3389)
        XCTAssertEqual(ssh.host, "10.0.0.5")
        XCTAssertEqual(ssh.name, "10.0.0.5")
    }

    /// An explicit port wins over the protocol default: the user typed it.
    func testExplicitPortWins() {
        let target = AdHocTarget.parse("10.0.0.5:2222")!
        XCTAssertEqual(AdHocConnection.makeNode(for: target, protocol: .ssh).port, 2222)
    }

    func testUsernameIsCarried() {
        let target = AdHocTarget.parse("admin@10.0.0.5")!
        XCTAssertEqual(AdHocConnection.makeNode(for: target, protocol: .ssh).username, "admin")
    }

    /// The node is a plain connection: no folder, no children, and openable.
    func testNodeIsAnOpenableConnection() {
        let target = AdHocTarget.parse("10.0.0.5")!
        let node = AdHocConnection.makeNode(for: target, protocol: .ssh)
        XCTAssertFalse(node.isFolder)
        XCTAssertTrue(node.isOpenable)
        XCTAssertTrue(node.supportsSSH)
        XCTAssertFalse(node.supportsRDP)
    }
}
