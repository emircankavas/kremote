import Crypto
import Foundation
import Security

/// A `SecretStore` that keeps **one** Keychain item, not one per connection.
///
/// Why: the legacy (login) Keychain validates "Always Allow" against the
/// requesting binary's code signature, so a stored password's grant does not
/// survive an app update. With one Keychain item *per node* that means a dialog
/// **per connection** after every update — the "10 prompts after each release"
/// behaviour. This store instead holds a single random AES key in the Keychain
/// and keeps the passwords in a file encrypted with it, so an update can prompt
/// at most **once**.
///
/// The Data Protection Keychain (`kSecUseDataProtectionKeychain`) would avoid
/// even that, but it authorises by signing Team ID and needs a
/// `keychain-access-groups` entitlement — unavailable to a self-signed,
/// non-notarised build (it fails with `errSecMissingEntitlement`). So this stays
/// on the file-based Keychain, where a self-signed identity works, and absorbs
/// the cost by having a single item.
public final class EncryptedSecretStore: SecretStore {
    /// Keychain service for the master key; separate from the old per-node
    /// service so an existing install's items are left untouched.
    public static let masterKeyService = "com.emircankavas.kremote.masterkey"
    private static let masterKeyAccount = "master"

    /// File holding the encrypted secrets next to `tree.json`.
    private let fileURL: URL
    /// Test seam: when set, the master key comes from here instead of the
    /// Keychain (a headless session cannot unlock the login keychain).
    private let injectedKey: SymmetricKey?

    // Guarded by `lock`: `AppModel` is main-actor, but the store is also touched
    // from tests and may be read off the main thread.
    //
    // Recursive on purpose: `mutate`/`loadItems` hold the lock and then call
    // `encrypt`/`decrypt`, which reach `masterKey()` and take it again — with a
    // plain NSLock that self-nesting deadlocks (the app would hang on the first
    // secret read).
    private let lock = NSRecursiveLock()
    private var cachedKey: SymmetricKey?
    private var cachedItems: [String: Data]?

    public init(fileURL: URL = EncryptedSecretStore.defaultFileURL(), key: SymmetricKey? = nil) {
        self.fileURL = fileURL
        self.injectedKey = key
    }

    // MARK: - SecretStore

    public func secret(for id: UUID) throws -> String? {
        let items = try loadItems()
        guard let blob = items[id.uuidString] else { return nil }
        return try decrypt(blob)
    }

    public func setSecret(_ secret: String, for id: UUID) throws {
        try mutate { items in
            if secret.isEmpty {
                items[id.uuidString] = nil
            } else {
                items[id.uuidString] = try self.encrypt(secret)
            }
        }
    }

    public func removeSecret(for id: UUID) throws {
        try mutate { items in items[id.uuidString] = nil }
    }

    // MARK: - Storage

    private struct Envelope: Codable {
        var version: Int
        /// node id -> base64(nonce ‖ ciphertext ‖ tag)
        var items: [String: String]
    }

    private func loadItems() throws -> [String: Data] {
        lock.lock()
        defer { lock.unlock() }
        return try loadItemsLocked()
    }

    private func loadItemsLocked() throws -> [String: Data] {
        if let cached = cachedItems { return cached }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cachedItems = [:]
            return [:]
        }
        let data = try Data(contentsOf: fileURL)
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        var items: [String: Data] = [:]
        for (key, value) in envelope.items {
            if let blob = Data(base64Encoded: value) { items[key] = blob }
        }
        cachedItems = items
        return items
    }

    private func mutate(_ body: (inout [String: Data]) throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        var items = try loadItemsLocked()
        try body(&items)
        let envelope = Envelope(
            version: 1,
            items: items.mapValues { $0.base64EncodedString() }
        )
        let data = try JSONEncoder().encode(envelope)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // 0600: the file is encrypted, but there is no reason to make it
        // readable. Note: `.completeFileProtection` is an iOS data-protection
        // class and makes the write fail with EPERM on macOS, so it is not used.
        try data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        cachedItems = items
    }

    // MARK: - Crypto

    private func encrypt(_ plaintext: String) throws -> Data {
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: try masterKey())
        guard let combined = sealed.combined else { throw EncryptedSecretError.sealFailed }
        return combined
    }

    private func decrypt(_ blob: Data) throws -> String {
        let box = try AES.GCM.SealedBox(combined: blob)
        let plain = try AES.GCM.open(box, using: try masterKey())
        return String(decoding: plain, as: UTF8.self)
    }

    // MARK: - Master key

    /// Reads the master key, creating it on first use. A session-scoped key can
    /// be injected (tests/headless), otherwise it comes from the Keychain.
    private func masterKey() throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        if let cachedKey { return cachedKey }

        if let injectedKey {
            cachedKey = injectedKey
            return injectedKey
        }

        if let existing = try readMasterKeyFromKeychain() {
            let key = SymmetricKey(data: existing)
            cachedKey = key
            return key
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw EncryptedSecretError.keychain("generate", status)
        }
        let keyData = Data(bytes)
        try writeMasterKeyToKeychain(keyData)
        let key = SymmetricKey(data: keyData)
        cachedKey = key
        return key
    }

    private func readMasterKeyFromKeychain() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.masterKeyService,
            kSecAttrAccount as String: Self.masterKeyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw EncryptedSecretError.keychain("read", status)
        }
        return data
    }

    private func writeMasterKeyToKeychain(_ data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.masterKeyService,
            kSecAttrAccount as String: Self.masterKeyAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw EncryptedSecretError.keychain("add", status)
        }
    }
}

public enum EncryptedSecretError: Error, CustomStringConvertible {
    case sealFailed
    case keychain(String, OSStatus)

    public var description: String {
        switch self {
        case .sealFailed:
            return "Could not encrypt the secret."
        case .keychain(let operation, let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain \(operation) failed: \(message) (\(status))"
        }
    }
}

extension EncryptedSecretStore {
    /// `~/Library/Application Support/KRemote/secrets.enc`, beside `tree.json`.
    public static func defaultFileURL() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("KRemote", isDirectory: true)
            .appendingPathComponent("secrets.enc")
    }

    public static func defaultStore() -> EncryptedSecretStore {
        EncryptedSecretStore()
    }
}
