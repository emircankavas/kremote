import Foundation
import Security

/// Reads the pre-v1.5.0 password layout so it can be migrated.
///
/// Until v1.5.0 each connection and folder had its own generic-password item:
/// service `com.emircankavas.kremote`, account = the node's UUID, value = the
/// password as UTF-8. The login Keychain binds an item's "Always Allow" grant to
/// the requesting binary's signature, so after every update those items prompted
/// again — which is why the storage moved to one encrypted file with a single
/// Keychain key. This type exists only to carry the old items forward; it is not
/// used once migration has run.
public final class LegacyKeychainSecretStore {
    /// Service string the old store used. **Do not change**: it is the only way
    /// to find an existing install's items.
    public static let service = "com.emircankavas.kremote"

    private let service: String

    public init(service: String = LegacyKeychainSecretStore.service) {
        self.service = service
    }

    /// Whether any item under the old service exists at all.
    ///
    /// A single query with `kSecMatchLimitOne` in a non-interactive fashion, so
    /// it does not prompt once per node: `SecItemCopyMatching` without
    /// `kSecReturnData` reports existence without reading the secret.
    public func hasAnyStoredSecret() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    public func secret(for id: UUID) throws -> String? {
        var query = baseQuery(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw SecretStoreError(operation: "read (legacy)", status: status)
        }
        return String(data: data, encoding: .utf8)
    }

    public func removeSecret(for id: UUID) throws {
        let status = SecItemDelete(baseQuery(for: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError(operation: "delete (legacy)", status: status)
        }
    }

    private func baseQuery(for id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }
}
