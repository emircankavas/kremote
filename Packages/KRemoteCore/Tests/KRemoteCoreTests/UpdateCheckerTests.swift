import XCTest
@testable import KRemoteCore

final class UpdateCheckerTests: XCTestCase {

    private let releaseJSON = """
    {
      "tag_name": "v1.2.0",
      "name": "KRemote v1.2.0",
      "body": "### Fixed\\n- pane parking",
      "html_url": "https://github.com/emircankavas/kremote/releases/tag/v1.2.0",
      "published_at": "2026-10-14T10:45:43Z",
      "prerelease": false,
      "assets": [
        { "name": "KRemote-1.2.0.dmg", "browser_download_url": "https://example.com/KRemote-1.2.0.dmg" },
        { "name": "KRemote-1.2.0.zip", "browser_download_url": "https://example.com/KRemote-1.2.0.zip" }
      ]
    }
    """.data(using: .utf8)!

    func testParsesReleaseAndPicksTheZipAsset() throws {
        let info = try XCTUnwrap(UpdateChecker.parse(releaseJSON, currentVersion: "1.1.0"))
        XCTAssertEqual(info.latestVersion, "1.2.0")
        XCTAssertEqual(info.name, "KRemote v1.2.0")
        XCTAssertEqual(info.assetName, "KRemote-1.2.0.zip")
        XCTAssertEqual(info.assetURL, "https://example.com/KRemote-1.2.0.zip")
        XCTAssertFalse(info.prerelease)
        XCTAssertTrue(info.isNewer)
    }

    func testSameVersionIsNotNewer() throws {
        let info = try XCTUnwrap(UpdateChecker.parse(releaseJSON, currentVersion: "1.2.0"))
        XCTAssertFalse(info.isNewer)
    }

    func testOlderReleaseIsNotNewer() throws {
        let info = try XCTUnwrap(UpdateChecker.parse(releaseJSON, currentVersion: "2.0.0"))
        XCTAssertFalse(info.isNewer)
    }

    func testMalformedPayloadThrows() {
        let junk = Data("not json".utf8)
        XCTAssertThrowsError(try UpdateChecker.parse(junk, currentVersion: "1.0.0"))
    }

    func testMissingTagThrows() {
        let noTag = Data(#"{ "name": "x", "assets": [] }"#.utf8)
        XCTAssertThrowsError(try UpdateChecker.parse(noTag, currentVersion: "1.0.0"))
    }

    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isVersion("1.10.0", newerThan: "1.9.0"))
        XCTAssertFalse(UpdateChecker.isVersion("1.9.0", newerThan: "1.10.0"))
        XCTAssertTrue(UpdateChecker.isVersion("1.1", newerThan: "1.0.9"))
        XCTAssertFalse(UpdateChecker.isVersion("1.0.0", newerThan: "1.0.0"))
        XCTAssertTrue(UpdateChecker.isVersion("2", newerThan: "1.99.99"))
    }
}
