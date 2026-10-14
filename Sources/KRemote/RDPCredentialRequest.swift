import SwiftUI

/// The answer to an outstanding RDP credential request.
enum RDPCredentialAnswer {
    case supply(username: String, domain: String, password: String)
    case cancel
}

/// A one-line request for credentials from a live RDP session.
struct RDPCredentialRequest: Identifiable, Equatable {
    let id = UUID()
    /// Pre-fill values (the username/domain already in use, if any).
    let username: String
    let domain: String
    /// Filled in by the sheet when the user submits.
    var password: String = ""
    var resolvedUsername: String = ""
    var resolvedDomain: String = ""
}
