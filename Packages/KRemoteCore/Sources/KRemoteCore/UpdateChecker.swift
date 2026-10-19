import Foundation

/// Which release line the app follows. Beta is opt-in: a stable build stays on
/// stable until the user asks for beta in Software Update.
public enum UpdateChannel: String, Codable, Sendable, CaseIterable {
    case stable
    case beta

    public var displayName: String {
        switch self {
        case .stable: return "Stable"
        case .beta: return "Beta"
        }
    }
}

/// Information about a release fetched from the appcast.
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

/// Reads the update appcast published on Forgejo.
///
/// There is no GitHub dependency anywhere in the update path. The source
/// repository is private (`forgejo.kavas.dev/emircan/kremote`), and a private
/// repository's release API is not readable anonymously — which is exactly what
/// the installed app is. So the artifacts and the appcast live in a separate
/// **public** repository, `emircan/kremote-releases`:
///
/// - `appcast-stable.json` and `appcast-beta.json` on its `main` branch, and
/// - the `.zip` / `.dmg` attached to that repository's releases.
///
/// The appcast is a small JSON document written by the release workflow, so the
/// app needs no API token and no knowledge of Forgejo's release JSON.
public enum UpdateChecker {
    /// Public repository holding the appcast and the downloadable assets.
    public static let releasesOwner = "emircan"
    public static let releasesRepo = "kremote-releases"
    /// Forgejo instance that hosts the releases.
    public static let serverURL = "https://forgejo.kavas.dev"

    /// Channel the user follows. Defaults to stable on a fresh install.
    public static var channel: UpdateChannel {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "updateChannel"),
                  let channel = UpdateChannel(rawValue: raw) else { return .stable }
            return channel
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "updateChannel") }
    }

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

    /// URL of a channel's appcast.
    public static func appcastURL(channel: UpdateChannel) -> URL? {
        URL(string: "\(serverURL)/\(releasesOwner)/\(releasesRepo)/raw/branch/main/appcast-\(channel.rawValue).json")
    }

    /// The release page for a version, for the "Release Notes" button.
    public static func releasePage(version: String) -> String {
        "\(serverURL)/\(releasesOwner)/\(releasesRepo)/releases/tag/v\(version)"
    }

    /// Fetches the appcast for `channel` and decides whether it is newer than the
    /// running build. A missing appcast (HTTP 404) means "nothing published yet"
    /// and is not an error.
    ///
    /// Every parameter defaults to production values; they exist so tests can
    /// drive the parser and the request without the network.
    public static func check(
        channel: UpdateChannel = UpdateChecker.channel,
        currentVersion: String = UpdateChecker.currentVersion,
        appcastURL overrideURL: URL? = nil,
        session: URLSession = .shared
    ) async throws -> UpdateInfo? {
        guard let base = overrideURL ?? appcastURL(channel: channel) else { return nil }
        // Cache-buster: Forgejo's raw endpoint is fronted by a CDN, and a stale
        // appcast would hide a release the user was just told about.
        let stamp = Int(Date().timeIntervalSince1970)
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [URLQueryItem(name: "t", value: String(stamp))]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("KRemote", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CheckError.malformed }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else { throw CheckError.badResponse(http.statusCode) }

        return try parse(data, currentVersion: currentVersion)
    }

    /// Parses an appcast document. Separated from the request so it is testable
    /// without a network round-trip.
    public static func parse(_ data: Data, currentVersion: String) throws -> UpdateInfo? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CheckError.malformed
        }
        // `version` is what the workflow writes; `tag` is accepted too so a
        // hand-written appcast still works.
        let version: String
        if let v = obj["version"] as? String, !v.isEmpty {
            version = v.hasPrefix("v") ? String(v.dropFirst()) : v
        } else if let tag = obj["tag"] as? String, !tag.isEmpty {
            version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        } else {
            throw CheckError.malformed
        }

        let assets = obj["assets"] as? [String: Any] ?? [:]
        // The zip is what the in-app updater can swap in place; a dmg would have
        // to be mounted first, so it is only offered as a manual download.
        let zip = assets["zip"] as? String
        let dmg = assets["dmg"] as? String
        let page = (obj["page"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // Whichever asset we hand back needs its filename too: the updater writes
        // the download to that name before expanding it.
        let chosen = zip ?? dmg

        return UpdateInfo(
            currentVersion: currentVersion,
            latestVersion: version,
            name: (obj["name"] as? String) ?? "Version \(version)",
            notes: (obj["notes"] as? String) ?? "",
            htmlURL: page ?? releasePage(version: version),
            publishedAt: (obj["publishedAt"] as? String) ?? "",
            assetName: chosen.map { ($0 as NSString).lastPathComponent },
            assetURL: chosen,
            prerelease: (obj["prerelease"] as? Bool) ?? version.contains("-")
        )
    }

    /// Version comparison that understands a pre-release suffix.
    ///
    /// `1.10.0` beats `1.9.0`; `1.8.0` beats `1.8.0-beta.2`; and
    /// `1.8.0-beta.10` beats `1.8.0-beta.9` (numeric identifiers compare
    /// numerically, not as text). A plain dotted-number comparison — what this
    /// used to do — calls two betas of one version equal, so beta testers would
    /// never be offered the second beta.
    public static func isVersion(_ a: String, newerThan b: String) -> Bool {
        compare(a, b) > 0
    }

    /// Returns 1, 0 or -1 for `a` versus `b`.
    public static func compare(_ a: String, _ b: String) -> Int {
        let (an, ap) = split(a)
        let (bn, bp) = split(b)
        for i in 0..<max(an.count, bn.count) {
            let x = i < an.count ? an[i] : 0
            let y = i < bn.count ? bn[i] : 0
            if x != y { return x > y ? 1 : -1 }
        }
        // Same numeric core: the release outranks any pre-release of itself.
        switch (ap.isEmpty, bp.isEmpty) {
        case (true, true): return 0
        case (true, false): return 1
        case (false, true): return -1
        case (false, false): break
        }
        for i in 0..<max(ap.count, bp.count) {
            let x = i < ap.count ? ap[i] : ""
            let y = i < bp.count ? bp[i] : ""
            if x == y { continue }
            // A missing identifier ranks lower: "beta" < "beta.1".
            if x.isEmpty { return -1 }
            if y.isEmpty { return 1 }
            let xn = Int(x), yn = Int(y)
            if let xn, let yn { return xn > yn ? 1 : -1 }
            if xn != nil { return 1 }   // numeric identifiers rank above text
            if yn != nil { return -1 }
            return x > y ? 1 : -1
        }
        return 0
    }

    /// Splits "1.8.0-beta.2" into ([1,8,0], ["beta","2"]).
    public static func split(_ version: String) -> ([Int], [String]) {
        let trimmed = version.hasPrefix("v") ? String(version.dropFirst()) : version
        let parts = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let prerelease = parts.count > 1
            ? parts[1].split(separator: ".").map(String.init)
            : []
        return (numbers, prerelease)
    }
}
