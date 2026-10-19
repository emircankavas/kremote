import XCTest
@testable import KRemoteCore

/// Codec-level tests: framing, primitives, and the promise that hostile bytes
/// throw instead of crashing.
final class SFTPMessageTests: XCTestCase {

    // MARK: - Framing

    func testInitPacketLayout() {
        let packet = SFTPFraming.initPacket()
        XCTAssertEqual([UInt8](packet), [0, 0, 0, 5, 1, 0, 0, 0, 3])
    }

    func testFrameRoundTripsThroughTheParser() throws {
        let framed = SFTPFraming.frame(type: .open, id: 42, payload: SFTPRequests.open(path: "/tmp/x", flags: .read))
        let parsed = try XCTUnwrap(try SFTPFraming.parse([UInt8](framed)))
        XCTAssertEqual(parsed.0.type, .open)
        XCTAssertEqual(parsed.0.id, 42)
        XCTAssertEqual(parsed.1, framed.count)
        XCTAssertEqual(parsed.0.payload, SFTPRequests.open(path: "/tmp/x", flags: .read))
    }

    func testParserNeedsMoreBytesForAPartialHeader() throws {
        let framed = [UInt8](SFTPFraming.frame(type: .close, id: 1, payload: []))
        XCTAssertNil(try SFTPFraming.parse(Array(framed.prefix(2))))
        XCTAssertNil(try SFTPFraming.parse(Array(framed.prefix(framed.count - 1))))
        XCTAssertNotNil(try SFTPFraming.parse(framed))
    }

    func testParserRejectsAnAbsurdLength() {
        // length = 0xFFFFFFFF
        let bytes: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 101]
        XCTAssertThrowsError(try SFTPFraming.parse(bytes))
    }

    func testParserRejectsAnUnknownType() {
        var writer = SFTPWriter()
        writer.uint32(5)
        writer.uint8(0xEE)
        writer.uint32(1)
        XCTAssertThrowsError(try SFTPFraming.parse(writer.bytes))
    }

    func testVersionPacketHasNoRequestID() throws {
        var writer = SFTPWriter()
        writer.uint32(9)              // length
        writer.uint8(SFTPPacketType.version.rawValue)
        writer.uint32(3)              // version
        writer.string("ext")          // extensions are ignorable
        let parsed = try XCTUnwrap(try SFTPFraming.parse(writer.bytes))
        XCTAssertEqual(parsed.0.type, .version)
        XCTAssertEqual(parsed.0.version, 3)
        XCTAssertNil(parsed.0.id)
    }

    // MARK: - Primitives

    func testBigEndianPrimitives() throws {
        var writer = SFTPWriter()
        writer.uint32(0x0102_0304)
        writer.uint64(0x0102_0304_0506_0708)
        writer.string("héllo")
        var reader = SFTPReader(writer.bytes)
        XCTAssertEqual(try reader.uint32(), 0x0102_0304)
        XCTAssertEqual(try reader.uint64(), 0x0102_0304_0506_0708)
        XCTAssertEqual(try reader.string(), "héllo")
    }

    func testShortBufferThrowsInsteadOfTrapping() {
        var reader = SFTPReader([0x00, 0x00])
        XCTAssertThrowsError(try reader.uint32())
    }

    func testStringLengthBeyondBufferThrows() {
        var writer = SFTPWriter()
        writer.uint32(100)            // claims 100 bytes
        writer.bytes.append(contentsOf: [1, 2, 3])
        var reader = SFTPReader(writer.bytes)
        XCTAssertThrowsError(try reader.string())
    }

    func testInvalidUTF8InAFilenameDoesNotThrow() throws {
        var writer = SFTPWriter()
        writer.rawData([0x66, 0x6F, 0xC0, 0x80])   // "fo" + invalid bytes
        var reader = SFTPReader(writer.bytes)
        let name = try reader.string()
        XCTAssertTrue(name.hasPrefix("fo"))
    }

    // MARK: - Attributes

    func testAttributesRoundTrip() throws {
        let attrs = SFTPAttributes(
            size: 4242,
            permissions: 0o100644,
            uid: 501,
            gid: 20,
            modified: Date(timeIntervalSince1970: 1_700_000_000)
        )
        var writer = SFTPWriter()
        writer.attributes(attrs)
        var reader = SFTPReader(writer.bytes)
        let decoded = try reader.attributes()
        XCTAssertEqual(decoded.size, 4242)
        XCTAssertEqual(decoded.permissions, 0o100644)
        XCTAssertEqual(decoded.uid, 501)
        XCTAssertEqual(decoded.gid, 20)
        XCTAssertEqual(decoded.modified?.timeIntervalSince1970, 1_700_000_000)
        XCTAssertTrue(decoded.isRegularFile)
        XCTAssertFalse(decoded.isDirectory)
        XCTAssertEqual(decoded.modeBits, 0o644)
    }

    func testDirectoryAndSymlinkDetection() {
        XCTAssertTrue(SFTPAttributes(permissions: 0o040755).isDirectory)
        XCTAssertTrue(SFTPAttributes(permissions: 0o120777).isSymlink)
        XCTAssertFalse(SFTPAttributes(permissions: 0o100644).isDirectory)
        XCTAssertFalse(SFTPAttributes().isDirectory)
    }

    /// Guards the bug a real OpenSSH server exposed: v3 packs uid+gid under one
    /// flag and atime+mtime under another. The v4 layout silently desynchronises
    /// the stream, so the raw wire bytes are asserted here, not just a round-trip
    /// through our own writer.
    func testAttributesUseTheV3FlagLayout() throws {
        var writer = SFTPWriter()
        writer.uint32(0x0000_0001 | 0x0000_0002 | 0x0000_0008)  // size, uidgid, acmodtime
        writer.uint64(99)        // size
        writer.uint32(501)       // uid
        writer.uint32(20)        // gid
        writer.uint32(1_700_000_000) // atime
        writer.uint32(1_700_000_100) // mtime

        var reader = SFTPReader(writer.bytes)
        let attrs = try reader.attributes()
        XCTAssertEqual(attrs.size, 99)
        XCTAssertEqual(attrs.uid, 501)
        XCTAssertEqual(attrs.gid, 20)
        XCTAssertEqual(attrs.modified?.timeIntervalSince1970, 1_700_000_100)
        XCTAssertEqual(reader.remaining, 0, "the attributes block must consume exactly its bytes")
    }

    func testExtendedAttributesBlockIsSkipped() throws {
        var writer = SFTPWriter()
        writer.uint32(0x8000_0000)    // extended flag
        writer.uint32(1)              // one pair
        writer.string("mime-type")
        writer.rawData([0x74, 0x78, 0x74])
        var reader = SFTPReader(writer.bytes)
        let attrs = try reader.attributes()
        XCTAssertNil(attrs.size)
        XCTAssertEqual(reader.remaining, 0)
    }

    // MARK: - Status

    func testStatusCodesDecode() throws {
        var writer = SFTPWriter()
        writer.uint32(SFTPStatusCode.permissionDenied.rawValue)
        writer.string("Access denied.")
        writer.string("en")
        var reader = SFTPReader(writer.bytes)
        let code = try reader.uint32()
        XCTAssertEqual(SFTPStatusCode(rawValue: code), .permissionDenied)
        XCTAssertEqual(try reader.string(), "Access denied.")
    }

    // MARK: - Request bodies

    func testOpenRequestCarriesFlagsAndPermissions() throws {
        let payload = SFTPRequests.open(
            path: "/etc/motd",
            flags: [.write, .creat, .trunc],
            attributes: SFTPAttributes(permissions: 0o600)
        )
        var reader = SFTPReader(payload)
        XCTAssertEqual(try reader.string(), "/etc/motd")
        let flags: UInt32 = try reader.uint32()
        XCTAssertEqual(flags, SFTPOpenFlags.write.rawValue | SFTPOpenFlags.creat.rawValue | SFTPOpenFlags.trunc.rawValue)
        let attrs = try reader.attributes()
        XCTAssertEqual(attrs.permissions, 0o600)
    }

    func testReadRequestClampsTheLength() throws {
        let payload = SFTPRequests.read(handle: [1, 2], offset: 9, length: 10_000_000)
        var reader = SFTPReader(payload)
        XCTAssertEqual(try reader.rawData(), [1, 2])
        XCTAssertEqual(try reader.uint64(), 9)
        XCTAssertEqual(try reader.uint32(), SFTPConstants.maxReadLength)
    }

    func testRenameCarriesBothPaths() throws {
        let payload = SFTPRequests.rename(from: "/a", to: "/b")
        var reader = SFTPReader(payload)
        XCTAssertEqual(try reader.string(), "/a")
        XCTAssertEqual(try reader.string(), "/b")
    }
}
