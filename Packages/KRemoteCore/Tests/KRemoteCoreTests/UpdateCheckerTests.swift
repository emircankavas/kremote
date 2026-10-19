import XCTest
@testable import KRemoteCore

final class UpdateCheckerTests: XCTestCase {

    private let stableAppcast = """
    {
      "version": "1.2.0",
      "name": "KRemote 1.2.0",
      "notes": "### Fixed\\n- pane parking",
      "page": "https://forgejo.kavas.dev/emircan/kremote-releases/releases/tag/v1.2.0",
      "publishedAt": "2026-10-14T10:45:43Z",
      "prerelease": false,
      "assets": {
        "zip": "https://forgejo.kavas.dev/emircan/kremote-releases/releases/download/v1.2.0/KRemote-1.2.0.zip",
        "dmg": "https://forgejo.kavas.dev/emircan/kremote-releases/releases/download/v1.2.0/KRemote-1.2.0.dmg"
      }
    }
    """.data(using: .utf8)!

    private let betaAppcast = """
    {
      "version": "1.2.0-beta.2",
      "name": "KRemote 1.2.0 beta 2",
      "notes": "beta",
      "prerelease": true,
      "assets": { "zip": "https://example.com/KRemote-1.2.0-beta.2.zip" }
    }
    """.data(using: .utf8)!

    // MARK: - Appcast parsing

    func testParsesAppcastAndPicksTheZipAsset() throws {
        let info = try XCTUnwrap(UpdateChecker.parse(stableAppcast, currentVersion: "1.1.0"))
        XCTAssertEqual(info.latestVersion, "1.2.0")
        XCTAssertEqual(info.name, "KRemote 1.2.0")
        XCTAssertEqual(info.assetName, "KRemote-1.2.0.zip")
        XCTAssertEqual(
            info.assetURL,
            "https://forgejo.kavas.dev/emircan/kremote-releases/releases/download/v1.2.0/KRemote-1.2.0.zip"
        )
        XCTAssertFalse(info.prerelease)
        XCTAssertTrue(info.isNewer)
    }

    func testAppcastFallsBackToDmgWhenNoZip() throws {
        let json = """
        { "version": "1.3.0", "assets": { "dmg": "https://example.com/KRemote-1.3.0.dmg" } }
        """.data(using: .utf8)!
        let info = try XCTUnwrap(UpdateChecker.parse(json, currentVersion: "1.2.0"))
        XCTAssertEqual(info.assetName, "KRemote-1.3.0.dmg")
        XCTAssertEqual(info.assetURL, "https://example.com/KRemote-1.3.0.dmg")
    }

    func testAppcastWithoutPageGetsAForgejoReleasePage() throws {
        let json = #"{ "version": "1.4.0", "assets": {} }"#.data(using: .utf8)!
        let info = try XCTUnwrap(UpdateChecker.parse(json, currentVersion: "1.0.0"))
        XCTAssertEqual(
            info.htmlURL,
            "https://forgejo.kavas.dev/emircan/kremote-releases/releases/tag/v1.4.0"
        )
        XCTAssertNil(info.assetURL)
    }

    func testAppcastAcceptsATagInsteadOfVersion() throws {
        let json = #"{ "tag": "v1.5.0", "assets": {} }"#.data(using: .utf8)!
        let info = try XCTUnwrap(UpdateChecker.parse(json, currentVersion: "1.0.0"))
        XCTAssertEqual(info.latestVersion, "1.5.0")
    }

    func testBetaIsFlaggedAsPrereleaseWhenFieldIsMissing() throws {
        let info = try XCTUnwrap(UpdateChecker.parse(betaAppcast, currentVersion: "1.0.0"))
        XCTAssertTrue(info.prerelease)
        XCTAssertEqual(info.latestVersion, "1.2.0-beta.2")
    }

    func testSameVersionIsNotNewer() throws {
        let info = try XCTUnwrap(UpdateChecker.parse(stableAppcast, currentVersion: "1.2.0"))
        XCTAssertFalse(info.isNewer)
    }

    func testOlderReleaseIsNotNewer() throws {
        let info = try XCTUnwrap(UpdateChecker.parse(stableAppcast, currentVersion: "2.0.0"))
        XCTAssertFalse(info.isNewer)
    }

    func testMalformedPayloadThrows() {
        let junk = Data("not json".utf8)
        XCTAssertThrowsError(try UpdateChecker.parse(junk, currentVersion: "1.0.0"))
    }

    func testMissingVersionAndTagThrows() {
        let noVersion = Data(#"{ "name": "x", "assets": {} }"#.utf8)
        XCTAssertThrowsError(try UpdateChecker.parse(noVersion, currentVersion: "1.0.0"))
    }

    // MARK: - Channel wiring

    func testAppcastURLsPointAtThePublicReleasesRepo() throws {
        let stable = try XCTUnwrap(UpdateChecker.appcastURL(channel: .stable))
        let beta = try XCTUnwrap(UpdateChecker.appcastURL(channel: .beta))
        XCTAssertEqual(
            stable.absoluteString,
            "https://forgejo.kavas.dev/emircan/kremote-releases/raw/branch/main/appcast-stable.json"
        )
        XCTAssertEqual(
            beta.absoluteString,
            "https://forgejo.kavas.dev/emircan/kremote-releases/raw/branch/main/appcast-beta.json"
        )
    }

    func testDefaultChannelIsStable() {
        UserDefaults.standard.removeObject(forKey: "updateChannel")
        XCTAssertEqual(UpdateChecker.channel, .stable)
    }

    func testChannelRoundTripsThroughUserDefaults() {
        UpdateChecker.channel = .beta
        XCTAssertEqual(UpdateChecker.channel, .beta)
        UpdateChecker.channel = .stable
        XCTAssertEqual(UpdateChecker.channel, .stable)
    }

    // MARK: - Version comparison

    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isVersion("1.10.0", newerThan: "1.9.0"))
        XCTAssertFalse(UpdateChecker.isVersion("1.9.0", newerThan: "1.10.0"))
        XCTAssertTrue(UpdateChecker.isVersion("1.1", newerThan: "1.0.9"))
        XCTAssertFalse(UpdateChecker.isVersion("1.0.0", newerThan: "1.0.0"))
        XCTAssertTrue(UpdateChecker.isVersion("2", newerThan: "1.99.99"))
    }

    /// The bug this guards: a dotted-number comparison sees "1.2.0" on both
    /// sides and refuses to offer beta 2 to somebody running beta 1.
    func testBetaOrdering() {
        XCTAssertTrue(UpdateChecker.isVersion("1.2.0-beta.2", newerThan: "1.2.0-beta.1"))
        XCTAssertFalse(UpdateChecker.isVersion("1.2.0-beta.1", newerThan: "1.2.0-beta.2"))
        XCTAssertTrue(UpdateChecker.isVersion("1.2.0-beta.10", newerThan: "1.2.0-beta.9"))
        XCTAssertTrue(UpdateChecker.isVersion("1.2.0", newerThan: "1.2.0-beta.5"))
        XCTAssertFalse(UpdateChecker.isVersion("1.2.0-beta.5", newerThan: "1.2.0"))
        XCTAssertTrue(UpdateChecker.isVersion("1.3.0-beta.1", newerThan: "1.2.9"))
        XCTAssertFalse(UpdateChecker.isVersion("1.2.9", newerThan: "1.3.0-beta.1"))
        XCTAssertFalse(UpdateChecker.isVersion("1.2.0-beta.1", newerThan: "1.2.0-beta.1"))
    }

    func testSplitSeparatesCoreAndPrerelease() {
        XCTAssertEqual(UpdateChecker.split("1.8.0-beta.2").0, [1, 8, 0])
        XCTAssertEqual(UpdateChecker.split("1.8.0-beta.2").1, ["beta", "2"])
        XCTAssertEqual(UpdateChecker.split("v1.8.0").1, [])
    }
}
