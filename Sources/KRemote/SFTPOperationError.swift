import Foundation
import KRemoteCore

/// One file operation that failed, with the name it was about.
///
/// The window builds its alert from this: the title names the item, the body comes
/// from `OperationFailureText` (the server's words plus whether sudo was tried).
struct OperationError: Error, Identifiable {
    let name: String
    let error: Error

    var id: String { name }
    var message: String { OperationFailureText.describe(error) }
}

/// A name the server would not accept, before any round-trip is attempted.
///
/// Not an `SFTPError`: nothing went to the network, and the alert should say the
/// name is the problem rather than quoting a server.
struct InvalidName: LocalizedError {
    var errorDescription: String? {
        "A name cannot be empty, contain “/”, or be “.” or “..”."
    }
}
