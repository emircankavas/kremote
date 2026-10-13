import Foundation
import Security

/// macOS Keychain-backed `SecretStore`. One generic-password item per node,
/// keyed by the node's UUID as the account and a fixed service string.
///
/// The app is not sandboxed, so no Keychain entitlement is required. If it is
/// ever sandboxed, add `keychain-access-groups` to the entitlements.
public final class KeychainSecretStore: SecretStore {
    private let service: String

    public init(service: String = "com.emircankavas.kremote") {
        self.service = service
    }

    private func baseQuery(for id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }

    public func secret(for id: UUID) throws -> String? {
        var query = baseQuery(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw SecretStoreError(operation: "read", status: status)
        }
        return String(data: data, encoding: .utf8)
    }

    public func setSecret(_ secret: String, for id: UUID) throws {
        guard !secret.isEmpty else {
            try removeSecret(for: id)
            return
        }
        let data = Data(secret.utf8)
        let query = baseQuery(for: id)
        let update: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = query
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw SecretStoreError(operation: "add", status: addStatus)
            }
        default:
            throw SecretStoreError(operation: "update", status: status)
        }
    }

    public func removeSecret(for id: UUID) throws {
        let status = SecItemDelete(baseQuery(for: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError(operation: "delete", status: status)
        }
    }
}
