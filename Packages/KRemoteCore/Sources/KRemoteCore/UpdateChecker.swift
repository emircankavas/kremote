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
    /// `CFBundleVersion` of the running build and of the offered release. The
    /// appcast only carries one when the release workflow stamped it; it is the
    /// tiebreaker when the marketing versions are equal (rule 4 of the roadmap:
    /// each beta iteration bumps the build number).
    public let currentBuild: Int?
    public let latestBuild: Int?

    public init(
        currentVersion: String,
        latestVersion: String,
        name: String,
        notes: String,
        htmlURL: String,
        publishedAt: String,
        assetName: String?,
        assetURL: String?,
        prerelease: Bool,
        currentBuild: Int? = nil,
        latestBuild: Int? = nil
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
        self.currentBuild = currentBuild
        self.latestBuild = latestBuild
    }

    /// True when the release is strictly newer than the running build: the
    /// marketing version decides (`1.8.0-beta.2 < 1.8.0-beta.10 < 1.8.0`), and
    /// the build number only breaks a tie between equal versions.
    public var isNewer: Bool {
        let order = UpdateChecker.compare(latestVersion, currentVersion)
        if order != 0 { return order > 0 }
        guard let latestBuild, let currentBuild else { return false }
        return latestBuild > currentBuild
    }
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

    /// Build number of the running bundle (`CFBundleVersion`). Only used to break
    /// a tie between two identical marketing versions.
    public static var currentBuild: Int? {
        if let n = Bundle.main.infoDictionary?["CFBundleVersion"] as? Int { return n }
        if let s = Bundle.main.infoDictionary?["CFBundleVersion"] as? String { return Int(s) }
        return nil
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

    /// Fetches the appcast for `channel` and decides which release to offer.
    /// A missing appcast (HTTP 404) means "nothing published yet" and is not an
    /// error.
    ///
    /// A **beta** user reads *both* appcasts: the beta one and the stable one,
    /// and is offered the newer of the two. That is the stable-fallback rule —
    /// a beta tester is moved onto the finished release once it ships. The
    /// reverse never happens: a stable user only ever reads the stable appcast
    /// and any `-beta` entry is discarded anyway.
    ///
    /// Every parameter defaults to production values; they exist so tests can
    /// drive the parser and the request without the network.
    public static func check(
        channel: UpdateChannel = UpdateChecker.channel,
        currentVersion: String = UpdateChecker.currentVersion,
        currentBuild: Int? = UpdateChecker.currentBuild,
        appcastURL overrideURL: URL? = nil,
        session: URLSession = .shared
    ) async throws -> UpdateInfo? {
        // `overrideURL` pins the request to a single document (tests, and any
        // caller that already knows which appcast it wants).
        let sources: [(channel: UpdateChannel, url: URL)]
        if let overrideURL {
            sources = [(channel, overrideURL)]
        } else {
            let channels: [UpdateChannel] = channel == .beta ? [.beta, .stable] : [.stable]
            sources = channels.compactMap { ch in
                appcastURL(channel: ch).map { (ch, $0) }
            }
        }
        guard !sources.isEmpty else { return nil }

        var candidates: [UpdateInfo] = []
        var primaryError: Error?
        for (index, source) in sources.enumerated() {
            do {
                if let info = try await fetch(
                    source.url,
                    currentVersion: currentVersion,
                    currentBuild: currentBuild,
                    session: session
                ) {
                    candidates.append(info)
                }
            } catch {
                // The channel the user actually chose must fail loudly; the
                // fallback appcast failing must not hide a good primary one.
                if index == 0 { primaryError = error }
            }
        }
        if let primaryError { throw primaryError }
        return select(from: candidates, channel: channel)
    }

    /// Picks the release to offer out of the appcasts that were fetched.
    ///
    /// - Stable: pre-release entries are discarded outright, so a stable user is
    ///   never offered a `-beta` build even if one is published on the beta
    ///   appcast or hand-written into the stable one.
    /// - Beta: everything is eligible, and the newest wins — `1.8.0` (the
    ///   finished release) therefore beats `1.8.0-beta.3`, which is the
    ///   stable-fallback rule from the roadmap.
    public static func select(
        from candidates: [UpdateInfo],
        channel: UpdateChannel
    ) -> UpdateInfo? {
        let eligible = candidates.filter { candidate in
            switch channel {
            case .stable: return !candidate.prerelease && !isPrereleaseVersion(candidate.latestVersion)
            case .beta: return true
            }
        }
        return eligible.max { a, b in
            let order = compare(a.latestVersion, b.latestVersion)
            if order != 0 { return order < 0 }
            // Same marketing version: the higher build number wins, and with no
            // build numbers the two are interchangeable.
            return (a.latestBuild ?? 0) < (b.latestBuild ?? 0)
        }
    }

    /// Fetches and parses one appcast. Returns `nil` for a 404 — "nothing
    /// published on this channel yet" is a normal state, not a failure.
    private static func fetch(
        _ base: URL,
        currentVersion: String,
        currentBuild: Int?,
        session: URLSession
    ) async throws -> UpdateInfo? {
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

        return try parse(data, currentVersion: currentVersion, currentBuild: currentBuild)
    }

    /// True when the version string carries a pre-release suffix
    /// (`1.8.0-beta.2`). Such a build is never offered on the stable channel.
    public static func isPrereleaseVersion(_ version: String) -> Bool {
        !split(version).1.isEmpty
    }

    /// Parses an appcast document. Separated from the request so it is testable
    /// without a network round-trip.
    public static func parse(
        _ data: Data,
        currentVersion: String,
        currentBuild: Int? = nil
    ) throws -> UpdateInfo? {
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
        // Optional `CFBundleVersion` of the release. Additive: an appcast written
        // before this field existed simply has no tiebreaker.
        let build: Int?
        if let n = obj["build"] as? Int {
            build = n
        } else if let s = obj["build"] as? String {
            build = Int(s)
        } else {
            build = nil
        }

        return UpdateInfo(
            currentVersion: currentVersion,
            latestVersion: version,
            name: (obj["name"] as? String) ?? "Version \(version)",
            notes: (obj["notes"] as? String) ?? "",
            htmlURL: page ?? releasePage(version: version),
            publishedAt: (obj["publishedAt"] as? String) ?? "",
            assetName: chosen.map { ($0 as NSString).lastPathComponent },
            assetURL: chosen,
            prerelease: (obj["prerelease"] as? Bool) ?? version.contains("-"),
            currentBuild: currentBuild,
            latestBuild: build
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
