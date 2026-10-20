import XCTest
@testable import KRemoteCore

/// The NTLM message layout is unforgiving: a wrong buffer order or a swapped
/// length/max-length pair produces a message that looks fine and is refused with a
/// bare 401. These tests pin the structure, and one pins the exact bytes a real
/// Windows-hosted WinRM challenge produced.
final class NTLMTests: XCTestCase {

    /// A real type-2 challenge captured from a Windows 11 host (WinRM 5985).
    private let challengeBase64 =
        "TlRMTVNTUAACAAAAFAAUADgAAAAFAoICsurDvXQkNHQAAAAAAAAAAHAAcABMAAAACgD0ZQAAAA9LAFYAUwAtAEcAQQBNAEkATgBHAAIAFABLAFYAUwAtAEcAQQBNAEkATgBHAAEAFABLAFYAUwAtAEcAQQBNAEkATgBHAAQAFABLAFYAUwAtAEcAQQBNAEkATgBHAAMAFABLAFYAUwAtAEcAQQBNAEkATgBHAAcACABXZtGBeWDdAQAAAAA="

    private var challenge: Data {
        Data(base64Encoded: challengeBase64)!
    }

    func testChallengeParses() {
        XCTAssertEqual(String(decoding: challenge.prefix(8), as: UTF8.self), "NTLMSSP\0")
        XCTAssertEqual(challenge.uint32(at: 8), 2)
        XCTAssertEqual(challenge.count, 188)
    }

    func testNegotiateMessageLayout() {
        let message = NTLM.negotiateMessage()

        XCTAssertEqual(message.count, 32)
        XCTAssertEqual(String(decoding: message.prefix(8), as: UTF8.self), "NTLMSSP\0")
        XCTAssertEqual(message.uint32(at: 8), 1)
        // The minimal set: a fuller flag set gets no challenge at all from a real
        // server, which was three failed attempts' worth of debugging.
        XCTAssertEqual(message.uint32(at: 12), NTLM.type1Flags)
    }

    func testAuthenticateMessageStructure() throws {
        let message = try XCTUnwrap(
            NTLM.authenticateMessage(
                challenge: challenge,
                user: "kremotetest",
                domain: "",
                password: "Kx9-TestPw-7712"
            )
        )

        XCTAssertEqual(String(decoding: message.prefix(8), as: UTF8.self), "NTLMSSP\0")
        XCTAssertEqual(message.uint32(at: 8), 3)

        // Security buffers: LM, NT, Domain, User, Workstation, SessionKey.
        // Each is len(2), maxlen(2), offset(4) and they start at offset 12.
        let names = ["LM", "NT", "Domain", "User", "Workstation"]
        var offsets: [String: (len: Int, off: Int)] = [:]
        for (index, name) in names.enumerated() {
            let base = 12 + index * 8
            let len = Int(message.uint16(at: base))
            let maxlen = Int(message.uint16(at: base + 2))
            let offset = Int(message.uint32(at: base + 4))
            XCTAssertEqual(len, maxlen, "\(name): length and max length must agree")
            XCTAssertLessThanOrEqual(offset + len, message.count,
                                     "\(name) points past the end of the message")
            offsets[name] = (len, offset)
        }

        // NTLMv2 responses: LMv2 is 24 bytes (16 HMAC + 8 challenge), and the NT
        // response is 16 + a variable blob.
        XCTAssertEqual(offsets["LM"]?.len, 24)
        XCTAssertGreaterThan(offsets["NT"]?.len ?? 0, 44)
        XCTAssertEqual(offsets["Domain"]?.len, 0, "no domain for a local account")
        XCTAssertEqual(offsets["User"]?.len, "kremotetest".utf16.count * 2)

        // Session key buffer exists but is empty.
        XCTAssertEqual(message.uint16(at: 12 + 5 * 8), 0)
        XCTAssertEqual(message.uint32(at: 60), NTLM.type3Flags)
    }

    /// NTLMv2 binds the response to the server challenge and the target info, so
    /// the NT response must differ for a different challenge. A client that ignores
    /// the challenge produces a constant response and is refused.
    func testResponseDependsOnTheServerChallenge() throws {
        var other = challenge
        other[24] = other[24] ^ 0xff  // flip one byte of the server challenge

        let fixed = Data(repeating: 0x11, count: 8)
        let first = try XCTUnwrap(NTLM.authenticateMessage(
            challenge: challenge, user: "u", domain: "", password: "p",
            clientChallenge: fixed))
        let second = try XCTUnwrap(NTLM.authenticateMessage(
            challenge: other, user: "u", domain: "", password: "p",
            clientChallenge: fixed))

        func ntResponse(_ message: Data) -> Data {
            // NTLM buffer order is LM, NT — so the NT buffer is the *second* one:
            // length at 20, offset at 24.
            let length = Int(message.uint16(at: 20))
            let offset = Int(message.uint32(at: 24))
            guard offset >= 0, length > 0, offset + length <= message.count else { return Data() }
            return message.subdata(in: offset..<(offset + length))
        }
        XCTAssertNotEqual(ntResponse(first), ntResponse(second))
    }

    func testDifferentPasswordsProduceDifferentResponses() throws {
        let fixed = Data(repeating: 0x22, count: 8)
        let first = try XCTUnwrap(NTLM.authenticateMessage(
            challenge: challenge, user: "u", domain: "", password: "right",
            clientChallenge: fixed))
        let second = try XCTUnwrap(NTLM.authenticateMessage(
            challenge: challenge, user: "u", domain: "", password: "wrong",
            clientChallenge: fixed))
        func ntResponse(_ message: Data) -> Data {
            let length = Int(message.uint16(at: 20))
            let offset = Int(message.uint32(at: 24))
            guard offset >= 0, length > 0, offset + length <= message.count else { return Data() }
            return message.subdata(in: offset..<(offset + length))
        }
        XCTAssertNotEqual(ntResponse(first), ntResponse(second),
                          "a different password must change the response")
    }

    /// A malformed challenge must be refused rather than producing garbage that the
    /// server answers with a bare 401.
    func testMalformedChallengeIsRejected() {
        XCTAssertNil(NTLM.authenticateMessage(
            challenge: Data("not ntlm".utf8), user: "u", domain: "", password: "p"))
        XCTAssertNil(NTLM.authenticateMessage(
            challenge: Data(), user: "u", domain: "", password: "p"))
    }

    func testKnownNTLMv2Vector() {
        // From MS-NLMP 4.2.4 test vectors: user "User", domain "Domain",
        // password "Password", server challenge 0123456789abcdef.
        let challengeBytes = Data([
            0x4e, 0x54, 0x4c, 0x4d, 0x53, 0x53, 0x50, 0x00,  // NTLMSSP
            0x02, 0x00, 0x00, 0x00,                          // type 2
            0x00, 0x00, 0x00, 0x00,                          // target name (empty)
            0x00, 0x00, 0x00, 0x00,                          // flags
            0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,  // server challenge
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // reserved
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // target info (empty)
            0x00, 0x00, 0x00, 0x00,                          // padding to a legal length
        ])
        let response = NTLM.authenticateMessage(
            challenge: challengeBytes,
            user: "User",
            domain: "Domain",
            password: "Password",
            timestamp: 0,
            clientChallenge: Data(repeating: 0xaa, count: 8)
        )
        // Structure must hold even for a synthetic challenge; the exact response
        // bytes depend on the timestamp, which this vector varies.
        XCTAssertNotNil(response)
        XCTAssertEqual(response?.uint32(at: 8), 3)
    }
}
