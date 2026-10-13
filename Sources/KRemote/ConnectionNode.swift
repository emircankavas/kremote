import Foundation

/// A node in the connection tree: either a folder or a leaf connection.
///
/// Faz 0 keeps this in-memory. Faz 1 makes it `Codable` and persists it to a
/// JSON store, at which point a stable `id` matters for round-tripping.
final class ConnectionNode: Identifiable, Hashable {
    enum Kind: String, Codable {
        case folder
        case connection
    }

    let id: UUID
    var kind: Kind
    var name: String

    // Leaf-only fields. Folders ignore them (attribute inheritance lands in Faz 1).
    var host: String
    var port: Int
    var username: String
    /// Protocol is a string for now so Faz 2's confCons importer can carry
    /// values it doesn't recognise (RDP, VNC, ...) without a model change.
    var protocolName: String

    var children: [ConnectionNode]

    init(
        id: UUID = UUID(),
        kind: Kind,
        name: String,
        host: String = "",
        port: Int = 22,
        username: String = "",
        protocolName: String = "SSH",
        children: [ConnectionNode] = []
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.protocolName = protocolName
        self.children = children
    }

    var isFolder: Bool { kind == .folder }

    /// Optional-typed children for SwiftUI's `OutlineGroup`; nil leaves it a leaf.
    var childNodes: [ConnectionNode]? { isFolder ? children : nil }

    /// "user@host:port" or a placeholder when the leaf is not configured yet.
    var subtitle: String {
        guard !isFolder else { return "\(children.count) item\(children.count == 1 ? "" : "s")" }
        guard !host.isEmpty else { return "not configured" }
        let user = username.isEmpty ? "" : "\(username)@"
        return "\(protocolName.lowercased())://\(user)\(host):\(port)"
    }

    static func == (lhs: ConnectionNode, rhs: ConnectionNode) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension ConnectionNode {
    static func folder(_ name: String, _ children: [ConnectionNode] = []) -> ConnectionNode {
        ConnectionNode(kind: .folder, name: name, children: children)
    }

    static func connection(
        _ name: String,
        host: String,
        port: Int = 22,
        username: String = "",
        protocolName: String = "SSH"
    ) -> ConnectionNode {
        ConnectionNode(
            kind: .connection,
            name: name,
            host: host,
            port: port,
            username: username,
            protocolName: protocolName
        )
    }

    /// Fake tree so Faz 0 has something to render. Replaced by real data in Faz 1.
    static var sample: [ConnectionNode] {
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
