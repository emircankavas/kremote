import XCTest
@testable import KRemoteCore

/// RDP is a first-class protocol in the tree: its settings live on the node,
/// inherit from folders like credentials do, and survive a confCons round-trip.
final class RDPOptionsTests: XCTestCase {

    // MARK: - Resolution parsing

    func testParsesModeNames() {
        XCTAssertEqual(RDPResolutionMode(mRemoteNG: "SmartSize"), .smartSize)
        XCTAssertEqual(RDPResolutionMode(mRemoteNG: "FitToWindow"), .fitToWindow)
        XCTAssertEqual(RDPResolutionMode(mRemoteNG: "Fullscreen"), .fullscreen)
        XCTAssertEqual(RDPResolutionMode(mRemoteNG: "FitToPanel"), .fitToWindow)
    }

    func testParsesLegacyPixelSizes() {
        // Old files stored a size, either bare or as `Res<W>x<H>`.
        XCTAssertEqual(RDPResolutionMode(mRemoteNG: "1920x1080"), .custom)
        XCTAssertEqual(RDPResolutionMode(mRemoteNG: "Res1366x768"), .custom)
        let size = RDPResolutionMode.parsePixelSize("Res1366x768")
        XCTAssertEqual(size?.width, 1366)
        XCTAssertEqual(size?.height, 768)
    }

    func testUnknownResolutionFallsBackToSmartSize() {
        XCTAssertEqual(RDPResolutionMode(mRemoteNG: "nonsense"), .smartSize)
        XCTAssertEqual(RDPResolutionMode(mRemoteNG: ""), .smartSize)
    }

    // MARK: - confCons attribute mapping

    func testReadsConfConsAttributes() {
        let settings = RDPSettings.fromConfConsAttributes([
            "Domain": "CORP",
            "Resolution": "FitToWindow",
            "Colors": "24bit",
            "RedirectClipboard": "true",
            "RedirectDrives": "false",
            "RedirectKeys": "true",
        ])
        XCTAssertEqual(settings.domain, "CORP")
        XCTAssertEqual(settings.resolution, .fitToWindow)
        XCTAssertEqual(settings.colorDepth, 24)
        XCTAssertEqual(settings.redirectClipboard, true)
        XCTAssertEqual(settings.redirectDrives, false)
        XCTAssertEqual(settings.redirectKeys, true)
        // Not present -> nil, which means "inherit".
        XCTAssertNil(settings.redirectPrinters)
        XCTAssertNil(settings.redirectSound)
    }

    func testReadsPixelSizeIntoCustomDimensions() {
        let settings = RDPSettings.fromConfConsAttributes(["Resolution": "1600x900"])
        XCTAssertEqual(settings.resolution, .custom)
        XCTAssertEqual(settings.customWidth, 1600)
        XCTAssertEqual(settings.customHeight, 900)
    }

    func testIgnoresUnrecognisedValuesInsteadOfFailing() {
        // A file with an exotic setting must still import; unknown bits are dropped.
        let settings = RDPSettings.fromConfConsAttributes([
            "Colors": "TrueColor",
            "RedirectClipboard": "maybe",
        ])
        XCTAssertNil(settings.colorDepth)
        XCTAssertNil(settings.redirectClipboard)
        XCTAssertTrue(settings.isEmpty)
    }

    func testRedirectAudioIsAcceptedAsSound() {
        // mRemoteNG writes both spellings across versions.
        XCTAssertEqual(RDPSettings.fromConfConsAttributes(["RedirectAudio": "true"]).redirectSound, true)
        XCTAssertEqual(RDPSettings.fromConfConsAttributes(["RedirectSound": "false"]).redirectSound, false)
    }

    func testAttributesRoundTripThroughTheSerializer() {
        let settings = RDPSettings(
            domain: "LAB",
            resolution: .custom,
            customWidth: 1280,
            customHeight: 800,
            colorDepth: 16,
            redirectClipboard: true,
            redirectKeys: false
        )
        let attributes = Dictionary(uniqueKeysWithValues: settings.confConsAttributes)
        let reloaded = RDPSettings.fromConfConsAttributes(attributes)
        XCTAssertEqual(reloaded.domain, "LAB")
        XCTAssertEqual(reloaded.resolution, .custom)
        XCTAssertEqual(reloaded.customWidth, 1280)
        XCTAssertEqual(reloaded.customHeight, 800)
        XCTAssertEqual(reloaded.colorDepth, 16)
        XCTAssertEqual(reloaded.redirectClipboard, true)
        XCTAssertEqual(reloaded.redirectKeys, false)
    }

    // MARK: - Inheritance

    func testOptionsInheritFromFolder() {
        let folder = ConnectionNode(
            kind: .folder,
            name: "Windows",
            rdp: RDPSettings(domain: "CORP", resolution: .fitToWindow, colorDepth: 16)
        )
        let child = ConnectionNode(
            kind: .connection,
            name: "srv",
            host: "10.0.0.5",
            protocolName: "RDP",
            rdp: RDPSettings(redirectDrives: true)
        )
        folder.children = [child]

        let options = try! XCTUnwrap(ConnectionNode.effective(for: child.id, in: [folder])).rdp
        XCTAssertEqual(options.domain, "CORP")
        XCTAssertEqual(options.resolution, .fitToWindow)
        XCTAssertEqual(options.colorDepth, 16)
        // The child's own setting wins where it differs.
        XCTAssertEqual(options.redirectDrives, true)
        // Unset anywhere -> the built-in default.
        XCTAssertEqual(options.redirectPrinters, false)
    }

    func testChildOverridesInheritedValue() {
        let folder = ConnectionNode(kind: .folder, name: "F", rdp: RDPSettings(domain: "CORP", colorDepth: 16))
        let child = ConnectionNode(kind: .connection, name: "c", host: "h", protocolName: "RDP", rdp: RDPSettings(colorDepth: 32))
        folder.children = [child]

        let options = try! XCTUnwrap(ConnectionNode.effective(for: child.id, in: [folder])).rdp
        XCTAssertEqual(options.domain, "CORP")
        XCTAssertEqual(options.colorDepth, 32)
    }

    func testDefaultsWhenNothingIsSet() {
        let node = ConnectionNode(kind: .connection, name: "c", host: "h", protocolName: "RDP")
        let options = try! XCTUnwrap(ConnectionNode.effective(for: node.id, in: [node])).rdp
        XCTAssertEqual(options.resolution, .smartSize)
        XCTAssertEqual(options.colorDepth, 32)
        XCTAssertTrue(options.redirectClipboard)
        XCTAssertFalse(options.redirectDrives)
    }

    // MARK: - Derived values

    func testQualifiedUser() {
        let options = RDPOptions(domain: "CORP")
        XCTAssertEqual(options.qualifiedUser("alice"), "CORP\\alice")
        // No domain resolved -> bare user.
        XCTAssertEqual(RDPOptions().qualifiedUser("alice"), "alice")
        // A UPN already carries its realm.
        XCTAssertEqual(options.qualifiedUser("alice@corp.example"), "alice@corp.example")
    }

    func testExplicitDesktopSizeOnlyForCustom() {
        XCTAssertEqual(RDPOptions(resolution: .custom, customWidth: 1600, customHeight: 900)
            .explicitDesktopSize?.width, 1600)
        // The pane decides these, so no size is requested up front.
        XCTAssertNil(RDPOptions(resolution: .smartSize).explicitDesktopSize)
        XCTAssertNil(RDPOptions(resolution: .fullscreen).explicitDesktopSize)
        XCTAssertNil(RDPOptions(resolution: .fitToWindow).explicitDesktopSize)
    }

    // MARK: - Protocol classification

    func testRDPFamilyClassification() {
        XCTAssertTrue(RemoteProtocol.rdp.isRDPFamily)
        XCTAssertTrue(RemoteProtocol("RDP1").isRDPFamily)
        XCTAssertFalse(RemoteProtocol.ssh.isRDPFamily)
        XCTAssertEqual(RemoteProtocol.rdp.defaultPort, 3389)
    }

    func testNodeSupportFlags() {
        let rdp = ConnectionNode(kind: .connection, name: "r", host: "h", protocolName: "RDP")
        XCTAssertTrue(rdp.supportsRDP)
        XCTAssertFalse(rdp.supportsSSH)
        XCTAssertTrue(rdp.isOpenable)

        let ssh = ConnectionNode(kind: .connection, name: "s", host: "h", protocolName: "SSH2")
        XCTAssertTrue(ssh.supportsSSH)
        XCTAssertFalse(ssh.supportsRDP)

        let vnc = ConnectionNode(kind: .connection, name: "v", host: "h", protocolName: "VNC")
        XCTAssertFalse(vnc.isOpenable)

        let folder = ConnectionNode(kind: .folder, name: "f", protocolName: "RDP")
        XCTAssertFalse(folder.isOpenable, "folders are not openable")
    }

    // MARK: - Draft

    func testDraftCarriesRDPAndDetectsProtocol() {
        let node = ConnectionNode(
            kind: .connection,
            name: "r",
            host: "h",
            protocolName: "RDP",
            rdp: RDPSettings(domain: "CORP")
        )
        let draft = ConnectionDraft(from: node)
        XCTAssertTrue(draft.isRDP)
        XCTAssertEqual(draft.rdp.domain, "CORP")

        // An SSH node's draft still opens, it just reports non-RDP.
        let ssh = ConnectionNode(kind: .connection, name: "s", host: "h", protocolName: "SSH2")
        XCTAssertFalse(ConnectionDraft(from: ssh).isRDP)
        XCTAssertTrue(ConnectionDraft(from: ssh).rdp.isEmpty)
    }

    // MARK: - Persistence

    func testRDPBlockSurvivesJSONRoundTrip() throws {
        let node = ConnectionNode(
            kind: .connection,
            name: "r",
            host: "h",
            protocolName: "RDP",
            rdp: RDPSettings(domain: "CORP", resolution: .fitToWindow, redirectDrives: true)
        )
        let data = try JSONEncoder().encode([node])
        let decoded = try JSONDecoder().decode([ConnectionNode].self, from: data)
        let reloaded = try XCTUnwrap(decoded.first?.rdp)
        XCTAssertEqual(reloaded.domain, "CORP")
        XCTAssertEqual(reloaded.resolution, .fitToWindow)
        XCTAssertEqual(reloaded.redirectDrives, true)
    }

    func testEmptyRDPBlockIsNotWritten() throws {
        // A node with no RDP overrides must not grow an empty `rdp` object.
        let node = ConnectionNode(kind: .connection, name: "s", host: "h", protocolName: "SSH2")
        let json = String(decoding: try JSONEncoder().encode([node]), as: UTF8.self)
        XCTAssertFalse(json.contains("\"rdp\""))
    }

    func testMalformedRDPBlockDoesNotSinkTheTree() throws {
        let json = """
        [ { "id": "55555555-5555-5555-5555-555555555555", "kind": "connection", "name": "x",
            "rdp": { "resolution": "not-a-mode" } } ]
        """
        let decoded = try JSONDecoder().decode([ConnectionNode].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.count, 1)
        // An unknown mode falls back to the documented default rather than
        // failing the load or silently meaning "inherit".
        XCTAssertEqual(decoded.first?.rdp?.resolution, .smartSize)
    }

    func testResolutionCasingIsAcceptedOnLoad() throws {
        // A hand-edited file may spell the mode however it likes.
        let json = """
        [ { "id": "66666666-6666-6666-6666-666666666666", "kind": "connection", "name": "x",
            "rdp": { "resolution": "fitToWindow", "colorDepth": 16 } } ]
        """
        let decoded = try JSONDecoder().decode([ConnectionNode].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.first?.rdp?.resolution, .fitToWindow)
        XCTAssertEqual(decoded.first?.rdp?.colorDepth, 16)
    }
}
