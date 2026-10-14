import XCTest
@testable import KRemoteCore

final class ConfConsImportTests: XCTestCase {

    private func fixtureData() throws -> Data {
        // `.copy("Fixtures")` preserves the directory, so the resource lives
        // under Fixtures/ in the bundle.
        guard let url = Bundle.module.url(
            forResource: "confCons-demo",
            withExtension: "xml",
            subdirectory: "Fixtures"
        ) else {
            XCTFail("Fixture confCons-demo.xml missing from test bundle")
            throw XCTSkip("fixture missing")
        }
        return try Data(contentsOf: url)
    }

    // MARK: - Crypto

    func testEncryptDecryptRoundTrip() throws {
        let encoded = try ConfConsCrypto.encrypt("hunter2", iterations: 1000)
        let decoded = try ConfConsCrypto.decrypt(encoded, iterations: 1000)
        XCTAssertEqual(String(data: decoded, encoding: .utf8), "hunter2")
    }

    func testBlobLayoutIsSaltNonceCiphertextTag() throws {
        let encoded = try ConfConsCrypto.encrypt("hello", iterations: 1000)
        let blob = try XCTUnwrap(Data(base64Encoded: encoded))
        // salt(16) + nonce(16) + ciphertext("hello" = 5, GCM does not pad) + tag(16)
        XCTAssertEqual(blob.count, 16 + 16 + 5 + 16)
    }

    func testDefaultsAreMR3mAnd1000Rounds() {
        XCTAssertEqual(ConfConsCrypto.defaultPassphrase, "mR3m")
        XCTAssertEqual(ConfConsCrypto.defaultKdfIterations, 1000)
    }

    func testMalformedBlobThrows() {
        XCTAssertThrowsError(try ConfConsCrypto.decrypt("not-base64!!!"))
        XCTAssertThrowsError(try ConfConsCrypto.decrypt(Data([0, 1, 2]).base64EncodedString()))
    }

    func testWrongPassphraseFailsToDecrypt() throws {
        let encoded = try ConfConsCrypto.encrypt("secret", passphrase: "correct", iterations: 1000)
        XCTAssertThrowsError(try ConfConsCrypto.decrypt(encoded, passphrase: "wrong", iterations: 1000))
    }

    // MARK: - Passphrase verification

    func testFixtureUsesDefaultPassphrase() throws {
        let tree = try ConfConsImporter.importTree(from: fixtureData())
        XCTAssertFalse(tree.usedCustomPassphrase)
    }

    func testVerifyPassphraseAgainstFixtureProtectedField() throws {
        // Pull the Protected attribute out and check both a good and a bad guess.
        let xml = String(decoding: try fixtureData(), as: UTF8.self)
        let field = try XCTUnwrap(
            xml.split(separator: "Protected=\"").dropFirst().first?.split(separator: "\"").first.map(String.init)
        )
        XCTAssertTrue(ConfConsCrypto.verifyPassphrase("mR3m", protectedField: field))
        XCTAssertFalse(ConfConsCrypto.verifyPassphrase("nope", protectedField: field))
        XCTAssertTrue(ConfConsCrypto.usesDefaultPassphrase(protectedField: field))
    }

    // MARK: - Import

    func testImportBuildsExpectedTree() throws {
        let result = try ConfConsImporter.importTree(from: fixtureData())

        // Two root folders (Prod, Lab); 6 nodes total.
        XCTAssertEqual(result.roots.count, 2)
        XCTAssertEqual(ConnectionNode.allNodes(in: result.roots).count, 6)
        XCTAssertEqual(result.roots.map(\.name), ["Prod", "Lab"])
        XCTAssertTrue(result.roots.allSatisfy(\.isFolder))
    }

    func testImportMapsFieldsAndDecryptsPasswords() throws {
        let result = try ConfConsImporter.importTree(from: fixtureData())
        let prod = try XCTUnwrap(result.roots.first { $0.name == "Prod" })
        let web = try XCTUnwrap(prod.children.first { $0.name == "web01" })

        XCTAssertEqual(web.kind, .connection)
        XCTAssertEqual(web.host, "192.0.2.10")
        XCTAssertEqual(web.port, 22)
        XCTAssertEqual(web.username, "deploy")
        XCTAssertEqual(web.protocolName, "SSH2")
        XCTAssertEqual(web.password, "alpha")

        let db = try XCTUnwrap(prod.children.first { $0.name == "db01" })
        XCTAssertEqual(db.port, 5432)
        XCTAssertEqual(db.password, "beta")

        let router = try XCTUnwrap(result.roots.first { $0.name == "Lab" }?.children.first { $0.name == "router" })
        XCTAssertEqual(router.password, "gamma")
    }

    func testPasswordsAreCollectedForKeychainAndEmptyOnesOmitted() throws {
        let result = try ConfConsImporter.importTree(from: fixtureData())
        // Three nodes carry passwords (web01, db01, router); "nopass" has none.
        XCTAssertEqual(result.passwords.count, 3)
        XCTAssertEqual(Set(result.passwords.values), ["alpha", "beta", "gamma"])

        let nopass = try XCTUnwrap(
            ConnectionNode.allNodes(in: result.roots).first { $0.name == "nopass" }
        )
        XCTAssertEqual(nopass.password, "")
    }

    func testImportRejectsWrongPassphrase() throws {
        XCTAssertThrowsError(try ConfConsImporter.importTree(from: fixtureData(), passphrase: "definitely-wrong")) { error in
            XCTAssertEqual(error as? ConfConsImporter.ImportError, .wrongPassphrase)
        }
    }

    func testImportRejectsGarbage() {
        let garbage = Data("this is not xml".utf8)
        XCTAssertThrowsError(try ConfConsImporter.importTree(from: garbage))
    }

    // MARK: - Round trip

    func testSerializeThenImportRoundTrips() throws {
        let first = try ConfConsImporter.importTree(from: fixtureData())

        let xml = try ConfConsSerializer.serialize(first.roots, iterations: 1000)
        let second = try ConfConsImporter.importTree(from: Data(xml.utf8))

        let firstNodes = ConnectionNode.allNodes(in: first.roots)
        let secondNodes = ConnectionNode.allNodes(in: second.roots)

        XCTAssertEqual(firstNodes.map(\.name), secondNodes.map(\.name))
        XCTAssertEqual(firstNodes.map(\.host), secondNodes.map(\.host))
        XCTAssertEqual(firstNodes.map(\.port), secondNodes.map(\.port))
        XCTAssertEqual(firstNodes.map(\.username), secondNodes.map(\.username))
        XCTAssertEqual(firstNodes.map(\.protocolName), secondNodes.map(\.protocolName))
        XCTAssertEqual(firstNodes.map(\.password), secondNodes.map(\.password))
        XCTAssertEqual(second.passwords, first.passwords)
    }

    func testSerializeEscapesXmlMetacharacters() throws {
        let node = ConnectionNode(kind: .connection, name: "A & B <\"x\">", host: "h")
        let xml = try ConfConsSerializer.serialize([node], iterations: 1000)
        XCTAssertFalse(xml.contains("A & B <")) // mangled into entities
        let reimported = try ConfConsImporter.importTree(from: Data(xml.utf8))
        XCTAssertEqual(reimported.roots.first?.name, "A & B <\"x\">")
    }

    // MARK: - Protocol helper

    func testProtocolDefaults() {
        XCTAssertTrue(RemoteProtocol.ssh.isSSHFamily)
        XCTAssertTrue(RemoteProtocol("SSH").isSSHFamily)
        XCTAssertFalse(RemoteProtocol.rdp.isSSHFamily)
        XCTAssertEqual(RemoteProtocol.ssh.defaultPort, 22)
        XCTAssertEqual(RemoteProtocol.https.defaultPort, 443)
    }

    // MARK: - RDP attributes

    func testImportReadsRDPAttributesFromAFolder() throws {
        let result = try ConfConsImporter.importTree(from: fixtureData())
        let prod = try XCTUnwrap(result.roots.first { $0.name == "Prod" })
        let rdp = try XCTUnwrap(prod.rdp, "the folder's RDP defaults must be carried")
        XCTAssertEqual(rdp.domain, "CORP")
        XCTAssertEqual(rdp.resolution, .fitToWindow)
        XCTAssertEqual(rdp.colorDepth, 16)
        XCTAssertEqual(rdp.redirectClipboard, true)
        XCTAssertEqual(rdp.redirectDrives, false)
        // Not present in the file -> nil (inherit), not a made-up default.
        XCTAssertNil(rdp.redirectPrinters)
    }

    func testImportLeavesUnsetRDPAttributesNil() throws {
        let result = try ConfConsImporter.importTree(from: fixtureData())
        let lab = try XCTUnwrap(result.roots.first { $0.name == "Lab" })
        // Lab declares RDP as its protocol but sets no appearance/redirection
        // attributes, so it carries no RDP block at all (rather than an empty one).
        XCTAssertNil(lab.rdp)
        // An SSH leaf has no RDP block either.
        let web = try XCTUnwrap(
            result.roots.first { $0.name == "Prod" }?.children.first { $0.name == "web01" }
        )
        XCTAssertNil(web.rdp)
    }

    func testRDPDefaultsInheritToAnRDPChild() throws {
        let result = try ConfConsImporter.importTree(from: fixtureData())
        // The web01 leaf is SSH, but a folder's RDP defaults still resolve for it;
        // what matters is that they reach an RDP connection. Reuse the folder.
        let prod = try XCTUnwrap(result.roots.first { $0.name == "Prod" })
        let rdpChild = ConnectionNode(kind: .connection, name: "win", host: "192.0.2.20", protocolName: "RDP")
        prod.children.append(rdpChild)

        let options = try XCTUnwrap(ConnectionNode.effective(for: rdpChild.id, in: result.roots)).rdp
        XCTAssertEqual(options.domain, "CORP")
        XCTAssertEqual(options.resolution, .fitToWindow)
        XCTAssertEqual(options.colorDepth, 16)
    }

    func testRPDAttributesRoundTripThroughTheFile() throws {
        let first = try ConfConsImporter.importTree(from: fixtureData())
        let xml = try ConfConsSerializer.serialize(first.roots, iterations: 1000)
        let second = try ConfConsImporter.importTree(from: Data(xml.utf8))

        func windowsFolder(_ result: ConfConsImporter.ImportResult) throws -> RDPSettings {
            try XCTUnwrap(try XCTUnwrap(result.roots.first { $0.name == "Prod" }).rdp)
        }
        let before = try windowsFolder(first)
        let after = try windowsFolder(second)
        XCTAssertEqual(after.domain, before.domain)
        XCTAssertEqual(after.resolution, before.resolution)
        XCTAssertEqual(after.colorDepth, before.colorDepth)
        XCTAssertEqual(after.redirectClipboard, before.redirectClipboard)
        XCTAssertEqual(after.redirectDrives, before.redirectDrives)
    }

    func testSerializerDoesNotEmitEmptyRDPAttributes() throws {
        let node = ConnectionNode(kind: .connection, name: "s", host: "h", protocolName: "SSH2")
        let xml = try ConfConsSerializer.serialize([node], iterations: 1000)
        XCTAssertFalse(xml.contains("Resolution="))
        XCTAssertFalse(xml.contains("Colors="))
        XCTAssertFalse(xml.contains("Redirect"))
    }
}
