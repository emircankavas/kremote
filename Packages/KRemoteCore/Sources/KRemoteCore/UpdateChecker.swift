import Foundation

/// Information about a release fetched from GitHub Releases.
public struct UpdateInfo: Sendable, Equatable {
    public let currentVersion: String
    public let latestVersion: String
    public let name: String
    public let notes: String
    public let htmlURL: String
    public let publishedAt: String
    public let assetName: String?
    public let assetURL: String?
    public let prerelease: Bool

    public init(
        currentVersion: String,
        latestVersion: String,
        name: String,
        notes: String,
        htmlURL: String,
        publishedAt: String,
        assetName: String?,
        assetURL: String?,
        prerelease: Bool
    ) {
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
        self.name = name
        self.notes = notes
        self.htmlURL = htmlURL
        self.publishedAt = publishedAt
        self.assetName = assetName
        self.assetURL = assetURL
        self.prerelease = prerelease
    }

    /// True when the release is strictly newer than the running build.
    public var isNewer: Bool { UpdateChecker.isVersion(latestVersion, newerThan: currentVersion) }
}

/// Fetches the latest GitHub release and decides whether it is newer than the
/// running app.
///
/// The release carries two assets: a `.dmg` for people who install by hand and a
/// `.zip` holding the bare `.app`, which is what the in-app updater replaces the
/// installed bundle with (a `.dmg` would need to be mounted first).
public enum UpdateChecker {
    public static let owner = "emircankavas"
    public static let repo = "kremote"

    /// Version reported by the running bundle (`CFBundleShortVersionString`).
    public static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    public enum CheckError: LocalizedError {
        case badResponse(Int)
        case malformed

        public var errorDescription: String? {
            switch self {
            case .badResponse(let code): return "Update check failed (HTTP \(code))."
            case .malformed: return "Update check returned an unexpected response."
            }
        }
    }

    /// `releaseURL`/`currentVersion` exist so tests can drive the parser without
    /// the network. Both default to the real repository and bundle version.
    public static func check(
        owner: String = UpdateChecker.owner,
        repo: String = UpdateChecker.repo,
        currentVersion: String = UpdateChecker.currentVersion,
        session: URLSession = .shared
    ) async throws -> UpdateInfo? {
        // Cache-buster: never answer with a stale release from a cached response.
        let stamp = Int(Date().timeIntervalSince1970)
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest?t=\(stamp)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("KRemote", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CheckError.malformed }
        // 404 means no release has been published yet; that is not an error.
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else { throw CheckError.badResponse(http.statusCode) }

        return try parse(data, currentVersion: currentVersion)
    }

    /// Parses the GitHub Releases JSON. Separated from the request so it is
    /// testable without a network round-trip.
    public static func parse(_ data: Data, currentVersion: String) throws -> UpdateInfo? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CheckError.malformed
        }
        let tag = (obj["tag_name"] as? String) ?? ""
        guard !tag.isEmpty else { throw CheckError.malformed }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = obj["assets"] as? [[String: Any]] ?? []
        // Prefer the zip: that is what can be swapped in place.
        let zipAsset = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }

        return UpdateInfo(
            currentVersion: currentVersion,
            latestVersion: version,
            name: (obj["name"] as? String) ?? "Version \(version)",
            notes: (obj["body"] as? String) ?? "",
            htmlURL: (obj["html_url"] as? String) ?? "",
            publishedAt: (obj["published_at"] as? String) ?? "",
            assetName: zipAsset?["name"] as? String,
            assetURL: zipAsset?["browser_download_url"] as? String,
            prerelease: (obj["prerelease"] as? Bool) ?? false
        )
    }

    /// Plain semantic-version comparison: "1.10.0" is newer than "1.9.0".
    public static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
