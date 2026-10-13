import Foundation

/// Identifies a protocol, keeping the raw mRemoteNG string so values the importer
/// doesn't recognise survive a round-trip (e.g. `SSH2`, `RDP`, `HTTPS`).
public struct RemoteProtocol: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static let ssh = RemoteProtocol("SSH2")
    public static let rdp = RemoteProtocol("RDP")
    public static let telnet = RemoteProtocol("Telnet")
    public static let http = RemoteProtocol("HTTP")
    public static let https = RemoteProtocol("HTTPS")
    public static let vnc = RemoteProtocol("VNC")

    /// mRemoteNG's spelling of the protocol (`SSH2` for SSH).
    public var displayName: String { rawValue }

    /// Normalised name for display and SSH-family checks.
    public var isSSHFamily: Bool {
        switch rawValue.uppercased() {
        case "SSH", "SSH1", "SSH2": return true
        default: return false
        }
    }

    /// The port mRemoteNG uses when a node leaves `Port` empty.
    public var defaultPort: Int {
        switch rawValue.uppercased() {
        case "SSH", "SSH1", "SSH2": return 22
        case "RDP": return 3389
        case "TELNET": return 23
        case "HTTP": return 80
        case "HTTPS": return 443
        case "VNC": return 5900
        default: return 0
        }
    }
}
