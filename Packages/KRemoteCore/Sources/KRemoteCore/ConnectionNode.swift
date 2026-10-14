import Foundation

/// A node in the connection tree: either a folder or a leaf connection.
///
/// Values are *directly set* per node. Empty string / port `0` means
/// "inherit from the parent" — the mRemoteNG model, resolved by `EffectiveConnection`.
/// This lets a folder carry defaults (username, domain, key, port) that every
/// connection below it picks up without repeating itself.
public final class ConnectionNode: Identifiable, Codable, Hashable {
    public enum Kind: String, Codable {
        case folder
        case connection
    }

    public let id: UUID
    public var kind: Kind
    public var name: String

    // Directly-set values. Empty / 0 means inherit.
    public var host: String
    /// `0` means inherit.
    public var port: Int
    public var username: String
    /// Empty means inherit. A string (not an enum) so Faz 2's confCons importer
    /// can carry protocols the model doesn't know about yet.
    public var protocolName: String

    /// Path to a private key (`ssh -i`). Empty means inherit.
    public var identityFile: String = ""
    /// Command to run on connect instead of an interactive shell. Empty = inherit
    /// (and ultimately an interactive shell).
    public var remoteCommand: String = ""

    /// RDP-specific overrides (domain, resolution, colour depth, redirections).
    /// `nil` fields inherit from the parent folder; `nil` as a whole means the
    /// node carries no RDP overrides at all and is not written to disk.
    public var rdp: RDPSettings?

    /// Directly-set password. Deliberately **not** in `CodingKeys`: it is never
    /// written to the JSON tree. `AppModel` mirrors it into the Keychain.
    public var password: String = ""

    public var children: [ConnectionNode]

    private enum CodingKeys: String, CodingKey {
        case id, kind, name, host, port, username, protocolName, children
        case identityFile, remoteCommand
        case rdp
    }

    public init(
        id: UUID = UUID(),
        kind: Kind,
        name: String,
        host: String = "",
        port: Int = 0,
        username: String = "",
        protocolName: String = "",
        identityFile: String = "",
        remoteCommand: String = "",
        rdp: RDPSettings? = nil,
        password: String = "",
        children: [ConnectionNode] = []
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.protocolName = protocolName
        self.identityFile = identityFile
        self.remoteCommand = remoteCommand
        self.rdp = rdp
        self.password = password
        self.children = children
    }

    /// Tolerant decoding: every field except `id`/`kind`/`name` falls back to a
    /// sensible default when its key is absent. Files written by older versions
    /// (before `identityFile`/`remoteCommand` existed) therefore keep loading
    /// instead of failing with `keyNotFound`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.kind = try container.decode(Kind.self, forKey: .kind)
        self.name = try container.decode(String.self, forKey: .name)
        self.host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        self.port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 0
        self.username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        self.protocolName = try container.decodeIfPresent(String.self, forKey: .protocolName) ?? ""
        self.identityFile = try container.decodeIfPresent(String.self, forKey: .identityFile) ?? ""
        self.remoteCommand = try container.decodeIfPresent(String.self, forKey: .remoteCommand) ?? ""
        // A malformed `rdp` block must not sink the whole tree — fall back to nil.
        self.rdp = (try? container.decodeIfPresent(RDPSettings.self, forKey: .rdp)) ?? nil
        // Passwords live in the Keychain, never in the tree file.
        self.password = ""
        self.children = try container.decodeIfPresent([ConnectionNode].self, forKey: .children) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(name, forKey: .name)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(username, forKey: .username)
        try container.encode(protocolName, forKey: .protocolName)
        try container.encode(identityFile, forKey: .identityFile)
        try container.encode(remoteCommand, forKey: .remoteCommand)
        if let rdp, !rdp.isEmpty { try container.encode(rdp, forKey: .rdp) }
        try container.encode(children, forKey: .children)
    }

    public var isFolder: Bool { kind == .folder }

    /// Whether KRemote can actually open a session for this leaf's resolved
    /// protocol. SSH-family protocols run the system `ssh`; RDP runs FreeRDP.
    /// Anything else is imported and stored so the tree round-trips, but has no
    /// session yet.
    public var supportsSSH: Bool { resolvedProtocol.isSSHFamily }

    /// Whether this leaf's resolved protocol is RDP (incl. `RDP` variants).
    public var supportsRDP: Bool { resolvedProtocol.isRDPFamily }

    /// Whether a session can be opened at all (SSH or RDP).
    public var isOpenable: Bool { !isFolder && (supportsSSH || supportsRDP) }

    /// The protocol this node resolves to, treating blank as the SSH default.
    public var resolvedProtocol: RemoteProtocol {
        RemoteProtocol(protocolName.isEmpty ? "SSH" : protocolName)
    }

    /// Optional-typed children for SwiftUI's `OutlineGroup`; nil marks a leaf.
    public var childNodes: [ConnectionNode]? { isFolder ? children : nil }

    public static func == (lhs: ConnectionNode, rhs: ConnectionNode) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Inheritance

/// The resolved settings of a node after walking the tree from the root down.
public struct EffectiveConnection: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var protocolName: String
    public var password: String
    public var identityFile: String
    public var remoteCommand: String
    /// RDP settings with folder inheritance already folded in.
    public var rdp: RDPOptions

    public init(
        host: String = "",
        port: Int = 22,
        username: String = "",
        protocolName: String = "SSH",
        password: String = "",
        identityFile: String = "",
        remoteCommand: String = "",
        rdp: RDPOptions = .default
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.protocolName = protocolName
        self.password = password
        self.identityFile = identityFile
        self.remoteCommand = remoteCommand
        self.rdp = rdp
    }

    /// What a root node starts from before any folder contributes.
    public static let `default` = EffectiveConnection()

    /// "user@host:port", or "not configured" when no host resolved.
    public var summary: String {
        guard !host.isEmpty else { return "not configured" }
        let user = username.isEmpty ? "" : "\(username)@"
        return "\(protocolName.lowercased())://\(user)\(host):\(port)"
    }
}

extension ConnectionNode {
    /// Folds this node's values over what it inherited.
    ///
    /// Only **credentials and RDP appearance/redirection settings** inherit:
    /// username, password, identity file, and the RDP options a group of servers
    /// shares. A folder is a group that logs in (and often looks) the same way,
    /// so those belong on the folder. Host, protocol, port and remote command are
    /// properties of an individual connection — a folder routinely holds SSH, RDP
    /// and HTTPS children at once, so inheriting a protocol from it would be wrong.
    public func effective(inheriting parent: EffectiveConnection?) -> EffectiveConnection {
        let base = parent ?? .default

        let resolvedProtocol = protocolName.isEmpty ? "SSH" : protocolName
        let resolvedPort: Int
        if port != 0 {
            resolvedPort = port
        } else {
            let protocolDefault = RemoteProtocol(resolvedProtocol).defaultPort
            resolvedPort = protocolDefault > 0 ? protocolDefault : 22
        }

        return EffectiveConnection(
            host: host,
            port: resolvedPort,
            username: username.isEmpty ? base.username : username,
            protocolName: resolvedProtocol,
            password: password.isEmpty ? base.password : password,
            identityFile: identityFile.isEmpty ? base.identityFile : identityFile,
            remoteCommand: remoteCommand,
            rdp: base.rdp.merging(rdp ?? RDPSettings())
        )
    }

    /// Resolved settings for a node somewhere in `roots`, or nil if not found.
    public static func effective(for id: UUID, in roots: [ConnectionNode]) -> EffectiveConnection? {
        func walk(_ nodes: [ConnectionNode], _ inherited: EffectiveConnection?) -> EffectiveConnection? {
            for node in nodes {
                let resolved = node.effective(inheriting: inherited)
                if node.id == id { return resolved }
                if let hit = walk(node.children, resolved) { return hit }
            }
            return nil
        }
        return walk(roots, nil)
    }
}

// MARK: - Tree operations

extension ConnectionNode {
    public static func find(_ id: UUID, in roots: [ConnectionNode]) -> ConnectionNode? {
        for node in roots {
            if node.id == id { return node }
            if let hit = find(id, in: node.children) { return hit }
        }
        return nil
    }

    /// Nodes in depth-first order.
    public static func allNodes(in roots: [ConnectionNode]) -> [ConnectionNode] {
        roots.flatMap { [$0] + allNodes(in: $0.children) }
    }

    /// The id of the folder containing `id`, or nil when `id` sits at the root.
    public static func parentID(of id: UUID, in roots: [ConnectionNode]) -> UUID? {
        func walk(_ nodes: [ConnectionNode], _ parent: UUID?) -> UUID? {
            for node in nodes {
                if node.id == id { return parent }
                if let hit = walk(node.children, node.id) { return hit }
            }
            return nil
        }
        return walk(roots, nil)
    }

    /// Removes a node and its subtree, returning the removed node (nil if absent).
    @discardableResult
    public static func remove(_ id: UUID, from roots: inout [ConnectionNode]) -> ConnectionNode? {
        if let index = roots.firstIndex(where: { $0.id == id }) {
            return roots.remove(at: index)
        }
        for parent in roots {
            if let removed = remove(id, from: &parent.children) { return removed }
        }
        return nil
    }

    /// Nodes in depth-first order whose own fields match `query`
    /// (case-insensitive substring over name, host, username, protocol).
    /// Resolved inherited values are deliberately not searched — only what the
    /// node itself carries, so results point at where the value actually lives.
    public static func search(_ query: String, in roots: [ConnectionNode]) -> [ConnectionNode] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return allNodes(in: roots).filter { node in
            let haystack = [node.name, node.host, node.username, node.protocolName]
                .joined(separator: "\n")
                .lowercased()
            return haystack.contains(needle)
        }
    }

    /// True when `node` is `maybeAncestor` or sits somewhere beneath it. Moving a
    /// node into its own subtree would detach that subtree from the tree.
    public static func contains(_ maybeAncestor: UUID, _ node: UUID, in roots: [ConnectionNode]) -> Bool {
        guard let ancestor = find(maybeAncestor, in: roots) else { return false }
        if maybeAncestor == node { return true }
        return find(node, in: ancestor.children) != nil
    }

    /// Moves `node` into `newParent` (nil = root). Returns false when the move is
    /// impossible (missing node, self, or into its own descendant).
    @discardableResult
    public static func move(
        _ node: UUID,
        to newParent: UUID?,
        in roots: inout [ConnectionNode]
    ) -> Bool {
        guard find(node, in: roots) != nil else { return false }
        if let newParent {
            guard find(newParent, in: roots) != nil else { return false }
            // Refuse to drop a node into itself or its own descendants.
            if contains(node, newParent, in: roots) { return false }
            // Only folders can hold children.
            guard find(newParent, in: roots)?.isFolder == true else { return false }
        }
        // Detach first, then attach, so an existing parent link does not duplicate.
        guard let detached = remove(node, from: &roots) else { return false }
        if let newParent, let parent = find(newParent, in: roots) {
            parent.children.append(detached)
        } else {
            roots.append(detached)
        }
        return true
    }
}

// MARK: - Editing

/// A flat, value-typed snapshot of an editable node. The editor sheet binds to
/// this so a cancelled edit never touches the live tree.
public struct ConnectionDraft: Equatable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var protocolName: String
    public var identityFile: String
    public var remoteCommand: String
    public var password: String
    /// Directly-set RDP overrides; `nil` fields mean "inherit from the folder".
    public var rdp: RDPSettings

    public init(
        id: UUID,
        name: String,
        host: String = "",
        port: Int = 0,
        username: String = "",
        protocolName: String = "",
        identityFile: String = "",
        remoteCommand: String = "",
        password: String = "",
        rdp: RDPSettings = RDPSettings()
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.protocolName = protocolName
        self.identityFile = identityFile
        self.remoteCommand = remoteCommand
        self.password = password
        self.rdp = rdp
    }

    public init(from node: ConnectionNode) {
        self.init(
            id: node.id,
            name: node.name,
            host: node.host,
            port: node.port,
            username: node.username,
            protocolName: node.protocolName,
            identityFile: node.identityFile,
            remoteCommand: node.remoteCommand,
            password: node.password,
            rdp: node.rdp ?? RDPSettings()
        )
    }

    /// True when the node's resolved protocol is RDP — used by the editor to
    /// show the RDP section.
    public var isRDP: Bool {
        RemoteProtocol(protocolName.isEmpty ? "SSH" : protocolName).isRDPFamily
    }
}

// MARK: - Fixtures

extension ConnectionNode {
    public static func folder(_ name: String, _ children: [ConnectionNode] = []) -> ConnectionNode {
        ConnectionNode(kind: .folder, name: name, children: children)
    }

    public static func connection(
        _ name: String,
        host: String,
        port: Int = 0,
        username: String = "",
        protocolName: String = "",
        rdp: RDPSettings? = nil
    ) -> ConnectionNode {
        ConnectionNode(
            kind: .connection,
            name: name,
            host: host,
            port: port,
            username: username,
            protocolName: protocolName,
            rdp: rdp
        )
    }

    /// First-run seed so the app isn't blank. Saved to disk, so it is
    /// user-editable and deletable like any other node.
    public static var sample: [ConnectionNode] {
        [
            .folder("Production", [
                .connection("web-01", host: "10.0.0.11", username: "deploy"),
                .connection("web-02", host: "10.0.0.12", username: "deploy"),
                .folder("Databases", [
                    .connection("pg-primary", host: "10.0.0.21", username: "postgres"),
                    .connection("pg-replica", host: "10.0.0.22", username: "postgres"),
                ]),
            ]),
            .folder("Lab", [
                .connection("router", host: "192.168.1.1", username: "admin"),
            ]),
        ]
    }
}
