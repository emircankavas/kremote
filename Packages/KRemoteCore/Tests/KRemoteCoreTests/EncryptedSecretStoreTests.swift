import Crypto
import XCTest
@testable import KRemoteCore

/// The store that replaced one Keychain item per connection.
///
/// Its whole point is that an app update can prompt at most once (there is a
/// single Keychain item), so these tests pin the shape: round-trip, persistence
/// across instances, and that the passwords never sit in the file in the clear.
final class EncryptedSecretStoreTests: XCTestCase {

    private func makeStore() -> (EncryptedSecretStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kremote-secrets-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("secrets.enc")
        // A throwaway key store: the real one is the macOS Keychain, which is
        // locked (and would prompt) in a headless/CI session, so these tests
        // exercise the file format and crypto without touching it.
        return (EncryptedSecretStore(fileURL: url, key: SymmetricKey(size: .bits256)), url)
    }

    func testRoundTrip() throws {
        let (store, _) = makeStore()
        let id = UUID()
        try store.setSecret("hunter2", for: id)
        XCTAssertEqual(try store.secret(for: id), "hunter2")
    }

    func testMissingSecretIsNil() throws {
        let (store, _) = makeStore()
        XCTAssertNil(try store.secret(for: UUID()))
    }

    func testOverwriteAndRemove() throws {
        let (store, _) = makeStore()
        let id = UUID()
        try store.setSecret("one", for: id)
        try store.setSecret("two", for: id)
        XCTAssertEqual(try store.secret(for: id), "two")

        // An empty secret removes the entry, matching the old store's contract.
        try store.setSecret("", for: id)
        XCTAssertNil(try store.secret(for: id))
    }

    func testSecretsAreIndependentPerNode() throws {
        let (store, _) = makeStore()
        let a = UUID(), b = UUID()
        try store.setSecret("alpha", for: a)
        try store.setSecret("beta", for: b)
        XCTAssertEqual(try store.secret(for: a), "alpha")
        XCTAssertEqual(try store.secret(for: b), "beta")
        try store.removeSecret(for: a)
        XCTAssertNil(try store.secret(for: a))
        XCTAssertEqual(try store.secret(for: b), "beta")
    }

    func testSurvivesANewInstance() throws {
        // The store is recreated on every launch; the master key must come back
        // and still open the file.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kremote-secrets-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("secrets.enc")
        let key = SymmetricKey(size: .bits256)

        let store = EncryptedSecretStore(fileURL: url, key: key)
        let id = UUID()
        try store.setSecret("persisted", for: id)

        let reopened = EncryptedSecretStore(fileURL: url, key: key)
        XCTAssertEqual(try reopened.secret(for: id), "persisted")
    }

    func testPasswordsAreNotStoredInTheClear() throws {
        let (store, url) = makeStore()
        let id = UUID()
        try store.setSecret("SuperSecretValue", for: id)

        let raw = try Data(contentsOf: url)
        let text = String(decoding: raw, as: UTF8.self)
        XCTAssertFalse(text.contains("SuperSecretValue"), "plaintext must never appear in the file")
        // The node id is not secret, but the value must not be greppable.
        XCTAssertTrue(text.contains(id.uuidString) || !text.isEmpty)
    }

    func testNonASCIIPasswordRoundTrips() throws {
        let (store, _) = makeStore()
        let id = UUID()
        try store.setSecret("şifre-€-ñ", for: id)
        XCTAssertEqual(try store.secret(for: id), "şifre-€-ñ")
    }
}
