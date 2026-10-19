import Foundation

/// The subset of SFTP v3 (draft-ietf-secsh-filexfer-02) that KRemote speaks.
///
/// Everything here is a pure value type + big-endian codec: no I/O, no force
/// unwraps, and every read is bounds-checked. That is deliberate — this code
/// parses bytes that come from a remote server, so a truncated or hostile packet
/// must throw rather than crash the app.
public enum SFTPConstants {
    /// We speak version 3, the version OpenSSH has negotiated for two decades.
    public static let version: UInt32 = 3

    /// Largest data payload we ask for in one READ. OpenSSH's own sftp client
    /// uses 32 KiB; going well above that gains little and risks servers that
    /// reject big packets.
    public static let maxReadLength: UInt32 = 32 * 1024
}

/// Packet type numbers, as they appear on the wire.
public enum SFTPPacketType: UInt8, Sendable {
    // client → server
    case initPacket = 1
    case open = 3
    case close = 4
    case read = 5
    case write = 6
    case lstat = 7
    case fstat = 8
    case setstat = 9
    case opendir = 11
    case readdir = 12
    case remove = 13
    case mkdir = 14
    case rmdir = 15
    case realpath = 16
    case stat = 17
    case rename = 18
    // server → client
    case version = 2
    case status = 101
    case handle = 102
    case data = 103
    case name = 104
    case attrs = 105
}

/// `SSH_FXF_*` open flags.
public struct SFTPOpenFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let read = SFTPOpenFlags(rawValue: 0x0000_0001)
    public static let write = SFTPOpenFlags(rawValue: 0x0000_0002)
    public static let append = SFTPOpenFlags(rawValue: 0x0000_0004)
    public static let creat = SFTPOpenFlags(rawValue: 0x0000_0008)
    public static let trunc = SFTPOpenFlags(rawValue: 0x0000_0010)
    public static let excl = SFTPOpenFlags(rawValue: 0x0000_0020)
}

/// `SSH_FX_*` status codes.
public enum SFTPStatusCode: UInt32, Sendable {
    case ok = 0
    case eof = 1
    case noSuchFile = 2
    case permissionDenied = 3
    case failure = 4
    case badMessage = 5
    case noConnection = 6
    case connectionLost = 7
    case opUnsupported = 8
}

/// A status reply. `message` is the server's human-readable text (often empty).
public struct SFTPStatus: Sendable, Equatable {
    public let code: SFTPStatusCode
    public let message: String
    /// Present only for `SSH_FX_FAILURE`-style replies that carry a language tag.
    public let language: String

    public init(code: SFTPStatusCode, message: String = "", language: String = "") {
        self.code = code
        self.message = message
        self.language = language
    }

    public var isOK: Bool { code == .ok }
    public var isEOF: Bool { code == .eof }
}

/// The attributes block (v3 `ATTRS`). Only the flags whose values are present
/// are meaningful; `permissions` keeps the raw st_mode (type bits included).
public struct SFTPAttributes: Sendable, Hashable {
    public var size: UInt64?
    /// Raw `st_mode` (e.g. 0o100644), including the file-type bits.
    public var permissions: UInt32?
    public var uid: UInt32?
    public var gid: UInt32?
    public var modified: Date?
    public var accessed: Date?

    public init(
        size: UInt64? = nil,
        permissions: UInt32? = nil,
        uid: UInt32? = nil,
        gid: UInt32? = nil,
        modified: Date? = nil,
        accessed: Date? = nil
    ) {
        self.size = size
        self.permissions = permissions
        self.uid = uid
        self.gid = gid
        self.modified = modified
        self.accessed = accessed
    }

    /// True for a directory, from the type bits of `st_mode`.
    public var isDirectory: Bool {
        guard let permissions else { return false }
        return (permissions & 0o170000) == 0o040000
    }

    /// True for a regular file.
    public var isRegularFile: Bool {
        guard let permissions else { return false }
        return (permissions & 0o170000) == 0o100000
    }

    /// True for a symbolic link (from LSTAT, which does not follow it).
    public var isSymlink: Bool {
        guard let permissions else { return false }
        return (permissions & 0o170000) == 0o120000
    }

    /// The permission bits only (`rwxr-xr-x` → 0o755).
    public var modeBits: UInt16 {
        UInt16((permissions ?? 0) & 0o7777)
    }
}

/// One directory entry from a NAME reply.
public struct SFTPNameEntry: Sendable, Equatable {
    public let filename: String
    public let longname: String
    public let attributes: SFTPAttributes

    public init(filename: String, longname: String, attributes: SFTPAttributes) {
        self.filename = filename
        self.longname = longname
        self.attributes = attributes
    }
}

/// Anything that can go wrong while talking to the server.
public enum SFTPError: Error, Sendable, Equatable {
    /// The server answered with a non-OK status.
    case status(SFTPStatusCode, message: String)
    /// The packet was truncated, mis-typed, or claimed a length it did not have.
    case malformedPacket(String)
    /// The peer closed the channel / the ssh process died.
    case connectionClosed(String)
    /// The transport could not start (ssh missing, fork failed, …).
    case transport(String)
    /// The operation was attempted with an unusable path or handle.
    case invalidArgument(String)
}

extension SFTPError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .status(let code, let message):
            let detail = message.isEmpty ? "" : " — \(message)"
            switch code {
            case .permissionDenied: return "Permission denied\(detail)"
            case .noSuchFile: return "No such file or directory\(detail)"
            case .opUnsupported: return "The server does not support this operation\(detail)"
            case .failure: return "The server reported a failure\(detail)"
            case .badMessage: return "The server rejected the request as malformed\(detail)"
            case .noConnection, .connectionLost: return "The SFTP connection was lost\(detail)"
            case .eof: return "End of file\(detail)"
            case .ok: return "Unexpected OK status\(detail)"
            }
        case .malformedPacket(let why): return "Malformed SFTP packet: \(why)"
        case .connectionClosed(let why): return "SFTP connection closed: \(why)"
        case .transport(let why): return "Could not start SFTP: \(why)"
        case .invalidArgument(let why): return "Invalid argument: \(why)"
        }
    }
}

// MARK: - Big-endian reader / writer

/// Reads the big-endian primitives of the protocol. Every read is checked; a
/// short buffer throws instead of trapping.
struct SFTPReader {
    private let bytes: [UInt8]
    private(set) var offset: Int = 0

    init(_ data: [UInt8]) { self.bytes = data }
    init(_ data: Data) { self.bytes = [UInt8](data) }

    var remaining: Int { bytes.count - offset }

    mutating func uint8() throws -> UInt8 {
        guard remaining >= 1 else { throw SFTPError.malformedPacket("truncated uint8") }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func uint32() throws -> UInt32 {
        guard remaining >= 4 else { throw SFTPError.malformedPacket("truncated uint32") }
        let value = UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
        offset += 4
        return value
    }

    mutating func uint64() throws -> UInt64 {
        let high = try uint32()
        let low = try uint32()
        return UInt64(high) << 32 | UInt64(low)
    }

    /// A `string`: uint32 length followed by that many bytes.
    mutating func rawData() throws -> [UInt8] {
        let length = Int(try uint32())
        guard length >= 0, remaining >= length else {
            throw SFTPError.malformedPacket("string length \(length) exceeds \(remaining) remaining bytes")
        }
        let slice = Array(bytes[offset..<(offset + length)])
        offset += length
        return slice
    }

    /// A `string` decoded as UTF-8. Invalid sequences become U+FFFD rather than
    /// failing: a filename in a legacy encoding must not break a listing.
    mutating func string() throws -> String {
        let raw = try rawData()
        return String(decoding: raw, as: UTF8.self)
    }

    /// Reads an attributes block.
    ///
    /// The v3 flag layout is NOT the v4 one: `UIDGID` is a single bit carrying
    /// both uid and gid, and `ACMODTIME` a single bit carrying both atime and
    /// mtime. Using the v4 bits here desynchronises the stream after the first
    /// entry — the server's timestamps then get read as string lengths.
    mutating func attributes() throws -> SFTPAttributes {
        let flags = try uint32()
        var attrs = SFTPAttributes()
        if flags & 0x0000_0001 != 0 { attrs.size = try uint64() }
        if flags & 0x0000_0002 != 0 {
            attrs.uid = try uint32()
            attrs.gid = try uint32()
        }
        if flags & 0x0000_0004 != 0 { attrs.permissions = try uint32() }
        if flags & 0x0000_0008 != 0 {
            attrs.accessed = try timestamp()
            attrs.modified = try timestamp()
        }
        // 0x80000000 is the v3 "extended attributes" flag; the block is a list we
        // do not use, but it still has to be skipped to stay in sync.
        if flags & 0x8000_0000 != 0 {
            let count = try uint32()
            for _ in 0..<min(count, 1_000) {
                _ = try string()   // type
                _ = try rawData()  // data
            }
        }
        return attrs
    }

    private mutating func timestamp() throws -> Date {
        Date(timeIntervalSince1970: TimeInterval(try uint32()))
    }
}

/// Writes the same primitives.
struct SFTPWriter {
    /// Exposed for the framing layer, which appends a pre-built payload.
    var bytes: [UInt8] = []

    mutating func uint8(_ value: UInt8) { bytes.append(value) }

    mutating func uint32(_ value: UInt32) {
        bytes.append(UInt8((value >> 24) & 0xff))
        bytes.append(UInt8((value >> 16) & 0xff))
        bytes.append(UInt8((value >> 8) & 0xff))
        bytes.append(UInt8(value & 0xff))
    }

    mutating func uint64(_ value: UInt64) {
        uint32(UInt32((value >> 32) & 0xffff_ffff))
        uint32(UInt32(value & 0xffff_ffff))
    }

    mutating func rawData(_ data: [UInt8]) {
        uint32(UInt32(data.count))
        bytes.append(contentsOf: data)
    }

    mutating func string(_ value: String) {
        rawData(Array(value.utf8))
    }

    mutating func attributes(_ attrs: SFTPAttributes) {
        var flags: UInt32 = 0
        if attrs.size != nil { flags |= 0x0000_0001 }
        // v3 packs uid+gid into one flag and atime+mtime into another.
        if attrs.uid != nil || attrs.gid != nil { flags |= 0x0000_0002 }
        if attrs.permissions != nil { flags |= 0x0000_0004 }
        if attrs.accessed != nil || attrs.modified != nil { flags |= 0x0000_0008 }
        uint32(flags)
        if let size = attrs.size { uint64(size) }
        if flags & 0x0000_0002 != 0 {
            uint32(attrs.uid ?? 0)
            uint32(attrs.gid ?? 0)
        }
        if let permissions = attrs.permissions { uint32(permissions) }
        if flags & 0x0000_0008 != 0 {
            uint32(UInt32(max(0, (attrs.accessed ?? attrs.modified ?? Date()).timeIntervalSince1970)))
            uint32(UInt32(max(0, (attrs.modified ?? attrs.accessed ?? Date()).timeIntervalSince1970)))
        }
    }

    var data: Data { Data(bytes) }
}

// MARK: - Packet framing

/// Builds and parses whole SFTP packets: `uint32 length | type | uint32 id | payload`.
///
/// `INIT` and `VERSION` are the one asymmetry in the protocol — they carry no
/// request id — so they have their own builders and parser.
public enum SFTPFraming {

    /// Frames a normal request/reply. `payload` is everything after the id.
    public static func frame(type: SFTPPacketType, id: UInt32, payload: [UInt8] = []) -> Data {
        var writer = SFTPWriter()
        writer.uint32(UInt32(4 + 1 + payload.count))  // length excludes itself
        writer.uint8(type.rawValue)
        writer.uint32(id)
        writer.bytes.append(contentsOf: payload)
        return writer.data
    }

    /// The opening `SSH_FXP_INIT` packet. No id: the length is 5, then 1, then
    /// the version.
    public static func initPacket(version: UInt32 = SFTPConstants.version) -> Data {
        var writer = SFTPWriter()
        writer.uint32(5)
        writer.uint8(SFTPPacketType.initPacket.rawValue)
        writer.uint32(version)
        return writer.data
    }

    /// A parsed server packet. `id` is nil for `VERSION`.
    public struct Packet: Sendable {
        public let type: SFTPPacketType
        public let id: UInt32?
        public let payload: [UInt8]
        public let version: UInt32?
    }

    /// Parses one packet from the front of `data`.
    ///
    /// Returns the packet plus the number of bytes consumed, so a caller reading
    /// from a stream can keep the remainder buffered. Throws when the header is
    /// incomplete (more bytes are needed) or when the length field disagrees
    /// with the packet type.
    public static func parse(_ data: [UInt8]) throws -> (Packet, Int)? {
        guard data.count >= 4 else { return nil }
        var reader = SFTPReader(data)
        let length = Int(try reader.uint32())
        // A sane v3 packet: at least type+id, and not absurdly large. OpenSSH
        // caps its own reads at 256 KiB; we allow 1 MiB for big attrs blocks.
        guard length >= 1, length <= 1024 * 1024 else {
            throw SFTPError.malformedPacket("packet length \(length) out of range")
        }
        guard data.count >= 4 + length else { return nil }
        var body = SFTPReader(Array(data[4..<(4 + length)]))
        let rawType = try body.uint8()
        guard let type = SFTPPacketType(rawValue: rawType) else {
            throw SFTPError.malformedPacket("unknown packet type \(rawType)")
        }
        if type == .version {
            let version = try body.uint32()
            return (.init(type: type, id: nil, payload: [], version: version), 4 + length)
        }
        let id = try body.uint32()
        let payload = Array(Array(data[4..<(4 + length)]).dropFirst(5))
        return (.init(type: type, id: id, payload: payload, version: nil), 4 + length)
    }
}

// MARK: - Request builders

/// Builders for each request body. Kept separate from the client so the codec can
/// be round-trip tested without a transport.
public enum SFTPRequests {
    public static func open(path: String, flags: SFTPOpenFlags, attributes: SFTPAttributes = SFTPAttributes()) -> [UInt8] {
        var writer = SFTPWriter()
        writer.string(path)
        writer.uint32(flags.rawValue)
        writer.attributes(attributes)
        return writer.bytes
    }

    public static func close(handle: [UInt8]) -> [UInt8] {
        var writer = SFTPWriter()
        writer.rawData(handle)
        return writer.bytes
    }

    public static func read(handle: [UInt8], offset: UInt64, length: UInt32) -> [UInt8] {
        var writer = SFTPWriter()
        writer.rawData(handle)
        writer.uint64(offset)
        writer.uint32(min(length, SFTPConstants.maxReadLength))
        return writer.bytes
    }

    public static func write(handle: [UInt8], offset: UInt64, data: [UInt8]) -> [UInt8] {
        var writer = SFTPWriter()
        writer.rawData(handle)
        writer.uint64(offset)
        writer.rawData(data)
        return writer.bytes
    }

    public static func pathOnly(_ path: String) -> [UInt8] {
        var writer = SFTPWriter()
        writer.string(path)
        return writer.bytes
    }

    /// Mkdir carries an attributes block. An all-zero block is legal, but OpenSSH
    /// applies the requested mode from it, so the mode is sent explicitly.
    public static func mkdir(path: String, permissions: UInt16) -> [UInt8] {
        var writer = SFTPWriter()
        writer.string(path)
        writer.attributes(SFTPAttributes(permissions: UInt32(permissions & 0o7777)))
        return writer.bytes
    }

    public static func rename(from: String, to: String) -> [UInt8] {
        var writer = SFTPWriter()
        writer.string(from)
        writer.string(to)
        return writer.bytes
    }

    public static func setstat(path: String, attributes: SFTPAttributes) -> [UInt8] {
        var writer = SFTPWriter()
        writer.string(path)
        writer.attributes(attributes)
        return writer.bytes
    }
}
