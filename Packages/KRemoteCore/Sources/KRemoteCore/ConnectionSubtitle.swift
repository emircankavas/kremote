import Foundation

/// The second line of a sidebar row: what a connection *is*, in one string.
///
/// This used to show the tree path, which answers "where in the sidebar is this?" — a
/// question nobody asks while scanning a list of servers. The address is what people look
/// for, so it leads. The rule about the port (print it only when it is not the protocol's
/// default) is the sort of thing that quietly regresses, so it lives here and is tested.
public enum ConnectionSubtitle {

    /// The address, with the username when there is one and the port when it is not the
    /// protocol's default.
    ///
    /// - Parameters:
    ///   - host: empty means the connection is not configured yet.
    ///   - username: empty means none is set.
    ///   - port: 0 or less means unset, which shows nothing.
    ///   - protocolName: empty is treated as SSH, matching how a node resolves itself.
    public static func address(
        host: String,
        username: String,
        port: Int,
        protocolName: String
    ) -> String? {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }

        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = user.isEmpty ? "" : "\(user)@"

        let portText: String
        if port > 0, port != defaultPort(for: protocolName) {
            portText = ":\(port)"
        } else {
            portText = ""
        }
        return "\(prefix)\(host)\(portText)"
    }

    /// Address first, then the folder path — so two entries with the same address in
    /// different folders stay distinguishable without the path pushing the address away.
    public static func address(_ address: String, path: [String]) -> String {
        guard !path.isEmpty else { return address }
        return "\(address) · \(path.joined(separator: " ▸ "))"
    }

    /// The port a protocol uses when a node leaves it unset.
    static func defaultPort(for protocolName: String) -> Int {
        RemoteProtocol(protocolName.isEmpty ? "SSH" : protocolName).defaultPort
    }
}
