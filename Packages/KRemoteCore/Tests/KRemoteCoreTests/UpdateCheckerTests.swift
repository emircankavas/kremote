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

    // MARK: - Version ordering as specified by the roadmap

    /// `1.8.0-beta.2 < 1.8.0-beta.10 < 1.8.0` — the exact chain from §2.
    func testRoadmapOrderingChain() {
        let chain = ["1.8.0-beta.2", "1.8.0-beta.10", "1.8.0"]
        for (lower, higher) in zip(chain, chain.dropFirst()) {
            XCTAssertTrue(
                UpdateChecker.isVersion(higher, newerThan: lower),
                "\(higher) should be newer than \(lower)"
            )
            XCTAssertFalse(
                UpdateChecker.isVersion(lower, newerThan: higher),
                "\(lower) should not be newer than \(higher)"
            )
        }
    }

    func testPrereleaseSuffixDetection() {
        XCTAssertTrue(UpdateChecker.isPrereleaseVersion("1.8.0-beta.2"))
        XCTAssertTrue(UpdateChecker.isPrereleaseVersion("v1.8.0-rc.1"))
        XCTAssertFalse(UpdateChecker.isPrereleaseVersion("1.8.0"))
        XCTAssertFalse(UpdateChecker.isPrereleaseVersion("v1.8.0"))
    }

    /// Build number breaks a tie between two identical marketing versions and
    /// only that: it must never outrank a higher marketing version.
    func testBuildNumberIsOnlyATiebreaker() throws {
        let json = #"{ "version": "1.8.0-beta.1", "build": 31, "assets": {} }"#.data(using: .utf8)!

        let sameVersionHigherBuild = try XCTUnwrap(
            UpdateChecker.parse(json, currentVersion: "1.8.0-beta.1", currentBuild: 30)
        )
        XCTAssertTrue(sameVersionHigherBuild.isNewer)

        let sameVersionSameBuild = try XCTUnwrap(
            UpdateChecker.parse(json, currentVersion: "1.8.0-beta.1", currentBuild: 31)
        )
        XCTAssertFalse(sameVersionSameBuild.isNewer)

        let sameVersionLowerBuild = try XCTUnwrap(
            UpdateChecker.parse(json, currentVersion: "1.8.0-beta.1", currentBuild: 32)
        )
        XCTAssertFalse(sameVersionLowerBuild.isNewer)

        // A newer marketing version wins even against a much higher build number.
        let newerVersion = try XCTUnwrap(
            UpdateChecker.parse(json, currentVersion: "1.8.0", currentBuild: 9999)
        )
        XCTAssertFalse(newerVersion.isNewer)

        // No build numbers on either side: equal versions are equal, not newer.
        let noBuild = try XCTUnwrap(
            UpdateChecker.parse(#"{ "version": "1.8.0-beta.1", "assets": {} }"#.data(using: .utf8)!,
                                currentVersion: "1.8.0-beta.1")
        )
        XCTAssertFalse(noBuild.isNewer)
    }

    // MARK: - Channel selection and stable fallback

    private func info(
        version: String,
        prerelease: Bool,
        build: Int? = nil,
        notes: String = ""
    ) throws -> UpdateInfo {
        var fields = "\"version\": \"\(version)\", \"assets\": { \"zip\": \"https://example.com/KRemote-\(version).zip\" }"
        if let build { fields += ", \"build\": \(build)" }
        if !notes.isEmpty { fields += ", \"notes\": \"\(notes)\"" }
        let data = Data("{\(fields)}".utf8)
        return try XCTUnwrap(
            UpdateChecker.parse(data, currentVersion: "1.7.11", currentBuild: 29)
        )
    }

    /// A stable user never gets a `-beta`, even when the beta appcast is newer
    /// and even when a beta leaked into the stable appcast.
    func testStableChannelNeverOffersAPrerelease() throws {
        let beta = try info(version: "1.8.0-beta.2", prerelease: true)
        let stable = try info(version: "1.7.11", prerelease: false)

        XCTAssertNil(UpdateChecker.select(from: [beta], channel: .stable))
        XCTAssertEqual(UpdateChecker.select(from: [beta, stable], channel: .stable)?.latestVersion, "1.7.11")

        // A pre-release mislabelled as stable is still caught by its version.
        let mislabelled = try info(version: "1.8.0-beta.2", prerelease: false)
        XCTAssertNil(UpdateChecker.select(from: [mislabelled], channel: .stable))
    }

    /// Beta users are offered the newest entry of all channels: a beta beats an
    /// older stable, and a newer stable beats a beta.
    func testBetaChannelTakesTheNewestAcrossBothAppcasts() throws {
        let beta = try info(version: "1.8.0-beta.2", prerelease: true)
        let olderStable = try info(version: "1.7.11", prerelease: false)
        let newerStable = try info(version: "1.8.0", prerelease: false)

        XCTAssertEqual(UpdateChecker.select(from: [beta, olderStable], channel: .beta)?.latestVersion, "1.8.0-beta.2")
        XCTAssertEqual(UpdateChecker.select(from: [beta, newerStable], channel: .beta)?.latestVersion, "1.8.0")
        XCTAssertEqual(UpdateChecker.select(from: [olderStable], channel: .beta)?.latestVersion, "1.7.11")
        XCTAssertNil(UpdateChecker.select(from: [], channel: .beta))
    }

    /// The two entries of one release (same version, different build numbers)
    /// resolve to the higher build.
    func testSelectUsesBuildNumberAsTiebreaker() throws {
        let low = try info(version: "1.8.0-beta.2", prerelease: true, build: 31)
        let high = try info(version: "1.8.0-beta.2", prerelease: true, build: 32)
        XCTAssertEqual(UpdateChecker.select(from: [low, high], channel: .beta)?.latestBuild, 32)
    }

    /// A beta user on 1.8.0-beta.1 is offered 1.8.0 once it ships, even though
    /// the beta appcast still advertises the beta.
    func testStableFallbackAppliesOnlyWhenStableIsNewerThanTheRunningBuild() throws {
        let beta = try info(version: "1.8.0-beta.1", prerelease: true)
        let stable = try info(version: "1.8.0", prerelease: false)
        let picked = try XCTUnwrap(UpdateChecker.select(from: [beta, stable], channel: .beta))
        XCTAssertEqual(picked.latestVersion, "1.8.0")
        XCTAssertFalse(picked.prerelease)
    }
}
