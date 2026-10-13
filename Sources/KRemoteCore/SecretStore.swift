import Foundation

/// Where a password lives. Real app: Keychain (`KeychainSecretStore`).
/// Tests: `InMemorySecretStore`.
public protocol SecretStore: AnyObject {
    func secret(for id: UUID) throws -> String?
    func setSecret(_ secret: String, for id: UUID) throws
    func removeSecret(for id: UUID) throws
}

public struct SecretStoreError: Error, CustomStringConvertible {
    public let operation: String
    public let status: OSStatus

    public init(operation: String, status: OSStatus) {
        self.operation = operation
        self.status = status
    }

    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "Keychain \(operation) failed: \(message) (\(status))"
    }
}

/// Trivial in-memory store, for tests and previews.
public final class InMemorySecretStore: SecretStore {
    private var storage: [UUID: String] = [:]

    public init() {}

    public func secret(for id: UUID) throws -> String? { storage[id] }

    public func setSecret(_ secret: String, for id: UUID) throws {
        if secret.isEmpty { storage[id] = nil } else { storage[id] = secret }
    }

    public func removeSecret(for id: UUID) throws { storage[id] = nil }
}
