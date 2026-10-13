import Foundation
import Crypto
import CryptoExtras

/// mRemoteNG's password encryption, reimplemented from the documented format.
///
/// Scheme (mRemoteNG >= 1.75, `EncryptionEngine="AES"`, `BlockCipherMode="GCM"`):
///
/// ```
/// blob   = base64decode(field)
/// salt   = blob[0..<16]          // also the GCM associated data (AAD)
/// nonce  = blob[16..<32]
/// tag    = blob[last 16]
/// ct     = blob[32..<last 16]
/// key    = PBKDF2-HMAC-SHA1(passphrase, salt, iterations, 32 bytes)
/// plain  = AES-GCM(key, nonce, aad = salt).open(ct, tag)
/// ```
///
/// Also used for the root `Protected` attribute, whose plaintext is the ASCII
/// marker `ThisIsProtected` / `ThisIsNotProtected` — decrypting it is how we tell
/// whether a supplied master passphrase is correct before touching node passwords.
///
/// Note: `AES.GCM.Nonce` in swift-crypto enforces a 12-byte *minimum*, and
/// mRemoteNG emits 16-byte nonces — which clears that floor and round-trips
/// intact (the nonce is treated as an opaque IV of arbitrary length).
public enum ConfConsCrypto {
    public static let defaultPassphrase = "mR3m"
    public static let defaultKdfIterations = 1000

    public static let protectedMarker = "ThisIsProtected"
    public static let notProtectedMarker = "ThisIsNotProtected"

    public enum CryptoError: Error, Equatable, CustomStringConvertible {
        case malformedBlob
        case decryptionFailed

        public var description: String {
            switch self {
            case .malformedBlob: return "Encrypted value is too short to be a valid mRemoteNG blob."
            case .decryptionFailed: return "Decryption failed — wrong master passphrase or corrupt data."
            }
        }
    }

    public enum HashAlgorithm: String {
        case sha1 = "SHA1"
        case md5 = "MD5"
        case sha256 = "SHA256"
    }

    /// Derives the 32-byte AES key mRemoteNG uses.
    public static func deriveKey(
        passphrase: String,
        salt: Data,
        iterations: Int,
        hash: HashAlgorithm = .sha1
    ) throws -> SymmetricKey {
        let hashFunction: KDF.Insecure.PBKDF2.HashFunction
        switch hash {
        case .sha1: hashFunction = .insecureSHA1
        case .md5: hashFunction = .insecureMD5
        case .sha256: hashFunction = .sha256
        }
        return try KDF.Insecure.PBKDF2.deriveKey(
            from: Data(passphrase.utf8),
            salt: salt,
            using: hashFunction,
            outputByteCount: 32,
            // mRemoteNG's default is 1000 rounds, far below swift-crypto's 210k
            // "safe" floor, so the unchecked entry point is the only option.
            unsafeUncheckedRounds: iterations
        )
    }

    /// Decrypts one base64 blob. `passphrase` defaults to mRemoteNG's public
    /// constant because most files never set a master password.
    public static func decrypt(
        _ base64: String,
        passphrase: String = defaultPassphrase,
        iterations: Int = defaultKdfIterations,
        hash: HashAlgorithm = .sha1
    ) throws -> Data {
        guard let blob = Data(base64Encoded: base64) else { throw CryptoError.malformedBlob }
        // salt(16) + nonce(>=12) + at least one ciphertext block + tag(16)
        guard blob.count >= 16 + 12 + 16 else { throw CryptoError.malformedBlob }

        let salt = blob.subdata(in: 0..<16)
        let nonceBytes = blob.subdata(in: 16..<32)
        let tag = blob.suffix(16)
        let ciphertext = blob.subdata(in: 32..<(blob.count - 16))

        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: iterations, hash: hash)
        do {
            let nonce = try AES.GCM.Nonce(data: nonceBytes)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(box, using: key, authenticating: salt)
        } catch {
            throw CryptoError.decryptionFailed
        }
    }

    /// Encrypts a value back to mRemoteNG's base64 layout. Used for round-trip
    /// tests and for writing files mRemoteNG can still read.
    public static func encrypt(
        _ plaintext: Data,
        passphrase: String = defaultPassphrase,
        iterations: Int = defaultKdfIterations,
        hash: HashAlgorithm = .sha1,
        salt: Data = randomBytes(16),
        nonce: Data = randomBytes(16)
    ) throws -> String {
        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: iterations, hash: hash)
        let gcmNonce = try AES.GCM.Nonce(data: nonce)
        let box = try AES.GCM.seal(plaintext, using: key, nonce: gcmNonce, authenticating: salt)
        let blob = salt + nonce + box.ciphertext + box.tag
        return blob.base64EncodedString()
    }

    public static func encrypt(
        _ plaintext: String,
        passphrase: String = defaultPassphrase,
        iterations: Int = defaultKdfIterations,
        hash: HashAlgorithm = .sha1
    ) throws -> String {
        try encrypt(Data(plaintext.utf8), passphrase: passphrase, iterations: iterations, hash: hash)
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        return Data(bytes)
    }
}

extension ConfConsCrypto {
    /// Whether `passphrase` is the correct master password for this file.
    ///
    /// mRemoteNG stores the ASCII marker `ThisIsNotProtected` (or
    /// `ThisIsProtected`) in the root `Protected` attribute; a successful decrypt
    /// proves the passphrase. Returns `false` for a wrong passphrase, never throws
    /// for that case.
    public static func verifyPassphrase(
        _ passphrase: String,
        protectedField: String,
        iterations: Int = defaultKdfIterations,
        hash: HashAlgorithm = .sha1
    ) -> Bool {
        guard let data = try? decrypt(protectedField, passphrase: passphrase, iterations: iterations, hash: hash),
              let text = String(data: data, encoding: .utf8)
        else { return false }
        return text == protectedMarker || text == notProtectedMarker
    }

    /// True when the file was written with mRemoteNG's public default passphrase
    /// (no user master password set) — the common case.
    public static func usesDefaultPassphrase(
        protectedField: String,
        iterations: Int = defaultKdfIterations,
        hash: HashAlgorithm = .sha1
    ) -> Bool {
        verifyPassphrase(defaultPassphrase, protectedField: protectedField, iterations: iterations, hash: hash)
    }
}
