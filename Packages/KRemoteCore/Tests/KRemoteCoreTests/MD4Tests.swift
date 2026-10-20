import XCTest
@testable import KRemoteCore

/// MD4 earns its tests: it is the one primitive where a wrong answer still looks
/// like a valid digest, and every NTLM failure downstream is a bare 401.
final class MD4Tests: XCTestCase {

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// RFC 1320, appendix A.5.
    func testRFC1320Vectors() {
        XCTAssertEqual(hex(MD4.hash([])), "31d6cfe0d16ae931b73c59d7e0c089c0")
        XCTAssertEqual(hex(MD4.hash(Array("a".utf8))), "bde52cb31de33e46245e05fbdbd6fb24")
        XCTAssertEqual(hex(MD4.hash(Array("abc".utf8))), "a448017aaf21d8525fc10ae87aa6729d")
        XCTAssertEqual(hex(MD4.hash(Array("message digest".utf8))),
                       "d9130a8164549fe818874806e1c7014b")
        XCTAssertEqual(hex(MD4.hash(Array("abcdefghijklmnopqrstuvwxyz".utf8))),
                       "d79e1c308aa5bbcdeea8ed63df412da9")
        XCTAssertEqual(hex(MD4.hash(Array("12345678901234567890123456789012345678901234567890123456789012345678901234567890".utf8))),
                       "e33b4ddc9c38f2199c3e7b164fcc0536")
    }

    /// The NT hash of a known password, as every NTLM implementation reports it:
    /// this is the value that must appear in the response key.
    func testKnownNTHash() {
        // "Password" → a4f49c406510bdcab6824ee7c30fd852 (public NTLM test vector).
        XCTAssertEqual(
            hex(MD4.hash(Array("Password".data(using: .utf16LittleEndian) ?? Data()))),
            "a4f49c406510bdcab6824ee7c30fd852"
        )
    }

    /// Block boundaries: 55, 56 and 64 bytes are where padding lands differently.
    func testBlockBoundaries() {
        XCTAssertEqual(MD4.hash(Array(repeating: 0x61, count: 55)).count, 16)
        XCTAssertEqual(MD4.hash(Array(repeating: 0x61, count: 56)).count, 16)
        XCTAssertEqual(MD4.hash(Array(repeating: 0x61, count: 64)).count, 16)
        // Different lengths must not collide, which a broken padding would cause.
        XCTAssertNotEqual(MD4.hash(Array(repeating: 0x61, count: 55)),
                          MD4.hash(Array(repeating: 0x61, count: 56)))
    }
}
