import XCTest
@testable import KRemoteCore

/// Records the requests `UpdateChecker.check` makes and answers them from a
/// table, so the channel wiring is exercised without a network.
final class AppcastStub: URLProtocol {
    /// `path -> (status, body)`. Paths are matched without the cache-buster
    /// query item, so the assertions read like the appcast names.
    nonisolated(unsafe) static var routes: [String: (Int, String)] = [:]
    nonisolated(unsafe) static var requested: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        AppcastStub.requested.append(path)
        let (status, body) = AppcastStub.routes[path] ?? (404, "Not found.")
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AppcastStub.self]
        return URLSession(configuration: config)
    }

    static func reset() {
        routes = [:]
        requested = []
    }

    static var requestedAppcasts: [String] {
        requested.compactMap { $0.split(separator: "/").last.map(String.init) }.sorted()
    }
}

final class UpdateCheckerChannelTests: XCTestCase {
    private let stablePath = "/emircan/kremote-releases/raw/branch/main/appcast-stable.json"
    private let betaPath = "/emircan/kremote-releases/raw/branch/main/appcast-beta.json"

    private func appcast(_ version: String, prerelease: Bool, notes: String = "notes") -> String {
        """
        {
          "version": "\(version)",
          "name": "KRemote \(version)",
          "notes": "\(notes)",
          "prerelease": \(prerelease),
          "assets": { "zip": "https://forgejo.kavas.dev/emircan/kremote-releases/releases/download/v\(version)/KRemote-\(version).zip" }
        }
        """
    }

    override func setUp() {
        super.setUp()
        AppcastStub.reset()
    }

    override func tearDown() {
        AppcastStub.reset()
        super.tearDown()
    }

    /// Switching to Stable queries only the stable appcast.
    func testStableCheckReachesOnlyTheStableAppcast() async throws {
        AppcastStub.routes[stablePath] = (200, appcast("1.7.11", prerelease: false))
        AppcastStub.routes[betaPath] = (200, appcast("1.8.0-beta.2", prerelease: true))

        let info = try await UpdateChecker.check(
            channel: .stable,
            currentVersion: "1.7.11",
            currentBuild: 29,
            session: AppcastStub.session()
        )
        XCTAssertEqual(info?.latestVersion, "1.7.11")
        XCTAssertEqual(AppcastStub.requestedAppcasts, ["appcast-stable.json"])
    }

    /// Switching to Beta queries the beta appcast first and then the stable one
    /// for the fallback.
    func testBetaCheckReachesBothAppcasts() async throws {
        AppcastStub.routes[betaPath] = (200, appcast("1.8.0-beta.2", prerelease: true))
        AppcastStub.routes[stablePath] = (200, appcast("1.7.11", prerelease: false))

        let info = try await UpdateChecker.check(
            channel: .beta,
            currentVersion: "1.7.11",
            currentBuild: 29,
            session: AppcastStub.session()
        )
        XCTAssertEqual(info?.latestVersion, "1.8.0-beta.2")
        XCTAssertEqual(AppcastStub.requestedAppcasts, ["appcast-beta.json", "appcast-stable.json"])
        XCTAssertEqual(AppcastStub.requested.first?.split(separator: "/").last, "appcast-beta.json")
    }

    /// A beta user is moved onto the finished release when it ships.
    func testBetaUserIsOfferedTheStableBuildOnceItShips() async throws {
        AppcastStub.routes[betaPath] = (200, appcast("1.8.0-beta.3", prerelease: true))
        AppcastStub.routes[stablePath] = (200, appcast("1.8.0", prerelease: false))

        let info = try await UpdateChecker.check(
            channel: .beta,
            currentVersion: "1.8.0-beta.3",
            currentBuild: 32,
            session: AppcastStub.session()
        )
        XCTAssertEqual(info?.latestVersion, "1.8.0")
        XCTAssertTrue(info?.isNewer ?? false)
    }

    /// 404 on the chosen channel means "nothing published yet": no throw, no
    /// update — on both channels.
    func testMissingAppcastIsNotAnErrorOnEitherChannel() async throws {
        AppcastStub.routes[betaPath] = (404, "Not found.")

        let stable = try await UpdateChecker.check(
            channel: .stable,
            currentVersion: "1.7.11",
            currentBuild: 29,
            session: AppcastStub.session()
        )
        XCTAssertNil(stable)

        AppcastStub.reset()
        AppcastStub.routes[betaPath] = (404, "Not found.")

        let beta = try await UpdateChecker.check(
            channel: .beta,
            currentVersion: "1.7.11",
            currentBuild: 29,
            session: AppcastStub.session()
        )
        XCTAssertNil(beta)
    }

    /// A 404 on the *fallback* appcast must not hide a good beta entry.
    func testMissingStableAppcastStillServesTheBeta() async throws {
        AppcastStub.routes[betaPath] = (200, appcast("1.8.0-beta.2", prerelease: true))

        let info = try await UpdateChecker.check(
            channel: .beta,
            currentVersion: "1.7.11",
            currentBuild: 29,
            session: AppcastStub.session()
        )
        XCTAssertEqual(info?.latestVersion, "1.8.0-beta.2")
    }

    /// A server error on the chosen channel surfaces as an error, not as
    /// "up to date".
    func testServerErrorOnTheChosenChannelThrows() async {
        AppcastStub.routes[betaPath] = (500, "boom")
        do {
            _ = try await UpdateChecker.check(
                channel: .beta,
                currentVersion: "1.7.11",
                currentBuild: 29,
                session: AppcastStub.session()
            )
            XCTFail("expected a CheckError")
        } catch {
            XCTAssertTrue(error is UpdateChecker.CheckError)
        }
    }
}
