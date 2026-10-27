import XCTest
@testable import KRemoteCore

/// The Retina bug: the desktop was requested in backing pixels while the server
/// was told the UI scale was 100%, so Windows drew a normal-sized UI into a 2x
/// surface — readable on a 1x monitor, unreadable on a MacBook.
final class RDPDesktopSizingTests: XCTestCase {

    private let pane = CGSize(width: 1200, height: 800)

    func testMatchDisplayUsesPointsAndKeepsTheScaleAtOneHundred() {
        let options = RDPOptions(desktopMode: .matchDisplay)
        let request = options.desktopRequest(panePoints: pane, backingScale: 2)
        XCTAssertEqual(request.width, 1200)
        XCTAssertEqual(request.height, 800)
        XCTAssertEqual(request.scaleFactor, 100)
    }

    func testNativeUsesBackingPixelsAndAsksForOneHundredEighty() {
        let options = RDPOptions(desktopMode: .native)
        let request = options.desktopRequest(panePoints: pane, backingScale: 2)
        XCTAssertEqual(request.width, 2400)
        XCTAssertEqual(request.height, 1600)
        XCTAssertEqual(request.scaleFactor, 180)
    }

    func testNativeOnAOneXDisplayDoesNotDoubleOrScale() {
        // The same grid as match-display, so announcing 180% would just inflate
        // the UI on an external 1x monitor.
        let options = RDPOptions(desktopMode: .native)
        let request = options.desktopRequest(panePoints: pane, backingScale: 1)
        XCTAssertEqual(request.width, 1200)
        XCTAssertEqual(request.height, 800)
        XCTAssertEqual(request.scaleFactor, 100)
    }

    func testCustomSizeWinsOverTheDesktopMode() {
        let options = RDPOptions(
            resolution: .custom, customWidth: 1600, customHeight: 900, desktopMode: .native
        )
        let request = options.desktopRequest(panePoints: pane, backingScale: 2)
        XCTAssertEqual(request.width, 1600)
        XCTAssertEqual(request.height, 900)
        XCTAssertEqual(request.scaleFactor, 100)
    }

    func testDefaultIsTheReadableMode() {
        XCTAssertEqual(RDPOptions().desktopMode, .matchDisplay)
        XCTAssertEqual(RDPDesktopMode.matchDisplay.wireScaleFactor, 100)
        XCTAssertEqual(RDPDesktopMode.native.wireScaleFactor, 180)
    }

    func testDesktopModeInheritsFromAFolder() {
        let folder = RDPSettings(desktopMode: .native)
        let merged = RDPOptions.default.merging(folder)
        XCTAssertEqual(merged.desktopMode, .native)
        // A child that sets nothing keeps what it inherited.
        XCTAssertEqual(merged.merging(RDPSettings()).desktopMode, .native)
        // A child that sets its own value wins.
        XCTAssertEqual(merged.merging(RDPSettings(desktopMode: .matchDisplay)).desktopMode, .matchDisplay)
    }

    func testInvertScrollInheritsAndSurvivesACodingRoundTrip() throws {
        let settings = RDPSettings(desktopMode: .native, invertScroll: true)
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(RDPSettings.self, from: data)
        XCTAssertEqual(decoded.desktopMode, .native)
        XCTAssertEqual(decoded.invertScroll, true)

        let merged = RDPOptions.default.merging(settings)
        XCTAssertTrue(merged.invertScroll)
        XCTAssertFalse(RDPOptions.default.invertScroll)
    }

    func testAnUnknownDesktopModeDecodesAsInheritRatherThanFailing() throws {
        // A settings block written by a newer build must not lose the rest of the
        // node's RDP settings (or the whole tree, on decode).
        let json = #"{"redirectClipboard": false, "desktopMode": "Hologram"}"#
        let decoded = try JSONDecoder().decode(RDPSettings.self, from: Data(json.utf8))
        XCTAssertNil(decoded.desktopMode)
        XCTAssertEqual(decoded.redirectClipboard, false)
    }

    func testDesktopModeRoundTripsThroughConfConsAttributes() {
        let settings = RDPSettings(desktopMode: .native, invertScroll: true)
        let attributes = Dictionary(uniqueKeysWithValues: settings.confConsAttributes)
        XCTAssertEqual(attributes["KRemoteDesktopMode"], "Native")
        XCTAssertEqual(attributes["KRemoteInvertScroll"], "true")

        let reread = RDPSettings.fromConfConsAttributes(attributes)
        XCTAssertEqual(reread.desktopMode, .native)
        XCTAssertEqual(reread.invertScroll, true)
    }
}
