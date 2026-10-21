import Foundation

/// What the search field understood from what was typed.
///
/// The sidebar's search box doubles as a way to reach a host that is not in the tree
/// yet: typing `10.0.31.11` or `root@server:2222` should offer a connection, not
/// "No matches". Parsing lives here rather than in the view so the rules are testable —
/// a host parser that silently mis-splits `user@host:port` sends a connection somewhere
/// the user did not ask for.
public struct AdHocTarget: Equatable, Sendable {
    /// Everything after `@`, before `:port`. As typed: a name or a literal address.
    public let host: String
    /// Empty when no `user@` was given.
    public let username: String
    /// nil when no `:port` was given, so RDP can fall back to 3389 and SSH to 22.
    public let port: Int?
    /// What the user typed, for the menu label.
    public let raw: String

    public init(host: String, username: String = "", port: Int? = nil, raw: String) {
        self.host = host
        self.username = username
        self.port = port
        self.raw = raw
    }

    /// Parses a search query as a connection target.
    ///
    /// Returns nil for anything that cannot be a host, so the "connect to…" row does not
    /// appear for a search that merely found nothing. The rules are deliberately narrow:
    ///
    /// - `host`
    /// - `host:port`
    /// - `user@host`
    /// - `user@host:port`
    ///
    /// A query containing a space is not a host — it is a search phrase — and neither is
    /// one with characters no hostname or address can hold.
    public static func parse(_ query: String) -> AdHocTarget? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }

        var rest = trimmed
        var username = ""
        if let at = rest.firstIndex(of: "@") {
            username = String(rest[..<at])
            rest = String(rest[rest.index(after: at)...])
            guard !username.isEmpty, !rest.isEmpty else { return nil }
        }

        var host = rest
        var port: Int?
        // A colon means a port, except inside an IPv6 literal, which is bracketed the
        // way every other tool writes it (`[::1]:22`).
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            let tail = rest[rest.index(after: close)...]
            if tail.hasPrefix(":") {
                guard let parsed = Int(tail.dropFirst()) else { return nil }
                port = parsed
            } else if !tail.isEmpty {
                return nil
            }
        } else if let colon = rest.lastIndex(of: ":") {
            // More than one colon and no brackets: an unbracketed IPv6 address, which
            // has no port and must not be split.
            if rest.filter({ $0 == ":" }).count == 1 {
                host = String(rest[..<colon])
                guard let parsed = Int(rest[rest.index(after: colon)...]) else { return nil }
                port = parsed
            }
        }

        guard !host.isEmpty, isValidHost(host) else { return nil }
        if let port, !(1...65535).contains(port) { return nil }
        return AdHocTarget(host: host, username: username, port: port, raw: trimmed)
    }

    /// Whether a string can be a host at all.
    ///
    /// Letters, digits, dots, hyphens, underscores and colons (IPv6) only. That rules out
    /// a sentence someone typed by mistake, without pretending to validate DNS.
    public static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:")
        guard host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        // A bare dot or dash is not a host.
        return host.contains(where: { $0.isLetter || $0.isNumber })
    }

    /// The menu label: what the user typed, so they can see it was understood.
    public var displayLabel: String { raw }

    /// Nodes in the tree that already point at this host.
    ///
    /// Offering "Connect to 10.0.31.11" when `10.0.31.11` is saved as *qs-ansible* would
    /// throw away the saved name, its folder (and the credentials inherited from that
    /// folder) and any RDP settings — for an address the app already knows. The saved
    /// entry wins; the ad-hoc row is only for hosts that are genuinely not there.
    public static func existingMatches(for target: AdHocTarget, in roots: [ConnectionNode]) -> [ConnectionNode] {
        ConnectionNode.allNodes(in: roots).filter { node in
            guard !node.isFolder, node.isOpenable else { return false }
            guard node.host.caseInsensitiveCompare(target.host) == .orderedSame else { return false }
            // A port the user typed narrows the match; without one, any saved port is
            // the same host.
            if let wanted = target.port, node.port != wanted { return false }
            return true
        }
    }
}

/// A host that was connected to without a tree entry.
///
/// Builds an ordinary `ConnectionNode` so the session, the SFTP window and the metrics
/// badge all work unchanged — they only ever see a node. The node is not inserted into
/// the tree: an ad-hoc connection is a session, not a saved favourite, and quietly
/// filling the sidebar with one-off hosts is the behaviour people resent.
public enum AdHocConnection {
    /// The node to open, given a parsed target and a chosen protocol.
    public static func makeNode(
        for target: AdHocTarget,
        protocol protocolName: RemoteProtocol
    ) -> ConnectionNode {
        ConnectionNode(
            kind: .connection,
            name: target.host,
            host: target.host,
            port: target.port ?? protocolName.defaultPort,
            username: target.username,
            protocolName: protocolName.rawValue
        )
    }
}
