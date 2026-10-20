import Foundation
import CryptoKit

/// NTLMv2, as WinRM over HTTP requires it.
///
/// WinRM's own transport is SOAP over HTTP; the only authentication a Windows box
/// offers out of the box is NTLM (or Basic, which sends the password in the clear
/// and is refused here on principle). NTLM is not in CryptoKit, so the message
/// construction lives here — verified against a real Windows host, and against
/// pywinrm's output byte for byte.
///
/// The password never leaves this file as anything but HMAC input.
public enum NTLM {
    /// Minimal flags for the negotiate message.
    ///
    /// Counter-intuitive but measured: this server answers a type-1 carrying the
    /// full flag set with a bare 401 and **no challenge at all**, and only offers a
    /// challenge for a minimal one. Sending fewer flags costs nothing — the type-3
    /// message is accepted with any of them.
    public static let type1Flags: UInt32 = 0x0000_0201  // UNICODE | NTLM

    /// Flags echoed in the authenticated message. EXTENDED_SESSIONSECURITY is set
    /// because the responses are NTLMv2 (keyed), not LM/NTLMv1.
    public static let type3Flags: UInt32 = 0x0008_8201

    /// A type-1 (Negotiate) message: what the client can do.
    public static func negotiateMessage() -> Data {
        var data = Data("NTLMSSP\0".utf8)
        data.append(uint32: 1)
        data.append(uint32: type1Flags)
        data.append(uint16: 0); data.append(uint16: 0); data.append(uint32: 0)
        data.append(uint16: 0); data.append(uint16: 0); data.append(uint32: 0)
        return data
    }

    /// Builds the type-3 (Authenticate) message for a server challenge.
    ///
    /// `timestamp` and `clientChallenge` are injectable so a test can reproduce a
    /// captured message exactly; production passes nil and gets fresh randomness.
    public static func authenticateMessage(
        challenge: Data,
        user: String,
        domain: String,
        password: String,
        workstation: String = "KREMOTE",
        timestamp: UInt64 = 0,
        clientChallenge: Data? = nil
    ) -> Data? {
        guard challenge.count >= 48, challenge.starts(with: Data("NTLMSSP\0".utf8)) else {
            return nil
        }

        let serverChallenge = challenge[24..<32]
        // TargetInfo is a security buffer at offset 40; NTLMv2 binds the response to
        // it, and an empty one breaks servers that authenticate local accounts.
        let infoLength = Int(challenge.uint16(at: 40))
        let infoOffset = Int(challenge.uint32(at: 44))
        guard infoOffset + infoLength <= challenge.count else { return nil }
        let targetInfo = infoLength > 0 ? challenge[infoOffset..<(infoOffset + infoLength)] : Data()

        let clientChallengeData = clientChallenge ?? randomBytes(8)

        // NTLMv2: NT hash → response key → HMAC-MD5 over (challenge || blob).
        let ntHash = MD4.hash(password.data(using: .utf16LittleEndian) ?? Data())
        let identity = (user.uppercased() + domain).data(using: .utf16LittleEndian) ?? Data()
        let responseKey = hmacMD5(key: ntHash, message: identity)

        var blob = Data([0x01, 0x01, 0x00, 0x00])
        blob.append(Data(repeating: 0, count: 4))
        blob.append(uint64: timestamp)
        blob.append(clientChallengeData)
        blob.append(Data(repeating: 0, count: 4))
        blob.append(targetInfo)
        blob.append(Data(repeating: 0, count: 4))

        let challengeAndBlob = Data(serverChallenge) + blob
        let ntProof = hmacMD5(key: responseKey, message: challengeAndBlob)
        let ntResponse = ntProof + blob

        // LMv2 is the same construction over the client challenge alone. It is not
        // needed by this server (an empty LM field is accepted) but some Windows
        // configurations insist on it, so it is sent.
        let lmProof = hmacMD5(key: responseKey, message: Data(serverChallenge) + clientChallengeData)
        let lmResponse = lmProof + clientChallengeData

        let domainBytes = domain.data(using: .utf16LittleEndian) ?? Data()
        let userBytes = user.data(using: .utf16LittleEndian) ?? Data()
        let workstationBytes = workstation.data(using: .utf16LittleEndian) ?? Data()

        // Six security buffers in a fixed order, then a payload area. Getting the
        // order wrong shifts every field and the server answers 401 without a word.
        var payload = Data()
        var buffers = Data()
        let base = 64
        for field in [lmResponse, ntResponse, domainBytes, userBytes, workstationBytes] {
            buffers.append(uint16: UInt16(field.count))
            buffers.append(uint16: UInt16(field.count))
            buffers.append(uint32: UInt32(base + payload.count))
            payload.append(field)
        }
        // Session key: empty, but still present as a buffer.
        buffers.append(uint16: 0)
        buffers.append(uint16: 0)
        buffers.append(uint32: UInt32(base + payload.count))

        var message = Data("NTLMSSP\0".utf8)
        message.append(uint32: 3)
        message.append(buffers)
        message.append(uint32: type3Flags)
        message.append(payload)
        return message
    }

    // MARK: - Primitives

    public static func hmacMD5(key: Data, message: Data) -> Data {
        let mac = HMAC<Insecure.MD5>.authenticationCode(for: message, using: .init(data: key))
        return Data(mac)
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        // `SystemRandomNumberGenerator` is cryptographically secure on Darwin.
        var generator = SystemRandomNumberGenerator()
        for index in 0..<count { bytes[index] = UInt8.random(in: 0...255, using: &generator) }
        return Data(bytes)
    }
}

// MARK: - Little-endian helpers

extension Data {
    mutating func append(uint16 value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func append(uint32 value: UInt32) {
        for shift in stride(from: 0, through: 24, by: 8) {
            append(UInt8((value >> UInt32(shift)) & 0xff))
        }
    }

    mutating func append(uint64 value: UInt64) {
        for shift in stride(from: 0, through: 56, by: 8) {
            append(UInt8((value >> UInt64(shift)) & 0xff))
        }
    }

    /// Reads a little-endian UInt16; 0 when the bytes are not there.
    func uint16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        let start = index(startIndex, offsetBy: offset)
        return UInt16(self[start]) | UInt16(self[start + 1]) << 8
    }

    /// Reads a little-endian UInt32; 0 when the bytes are not there.
    func uint32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        let start = index(startIndex, offsetBy: offset)
        return UInt32(self[start])
            | UInt32(self[start + 1]) << 8
            | UInt32(self[start + 2]) << 16
            | UInt32(self[start + 3]) << 24
    }
}
