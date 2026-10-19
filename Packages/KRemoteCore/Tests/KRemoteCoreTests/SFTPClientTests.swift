import XCTest
@testable import KRemoteCore

/// A scripted in-memory server. It answers requests from a closure so each test
/// describes only the conversation it cares about.
final class FakeSFTPTransport: SFTPTransport, @unchecked Sendable {
    /// Bytes the client wrote, in order (each `write` is one framed packet).
    private(set) var written: [[UInt8]] = []
    /// Packets the server still owes the client.
    private var pending: [Data] = []
    private var closed = false
    private var stderr = ""

    var onRequest: (([UInt8]) -> [Data])?
    /// Failed operations still record their write before erroring.
    var writeError: Error?

    func open() async throws {}

    func write(_ data: Data) throws {
        if let writeError { throw writeError }
        let bytes = [UInt8](data)
        written.append(bytes)
        guard let onRequest else { return }
        for reply in onRequest(bytes) { pending.append(reply) }
    }

    func read(maxLength: Int) throws -> Data? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    func stderrText() -> String { stderr }

    func close() { closed = true }

    var isAlive: Bool { !closed }

    /// Convenience: the type+id of the n-th request the client sent.
    func requestType(at index: Int) -> SFTPPacketType? {
        guard index < written.count else { return nil }
        var reader = SFTPReader(Array(written[index].dropFirst(4)))
        guard let raw = try? reader.uint8() else { return nil }
        return SFTPPacketType(rawValue: raw)
    }
}

/// Builds server replies in the shape a real server would.
enum FakeServer {
    static func version() -> Data {
        var writer = SFTPWriter()
        writer.uint32(5)
        writer.uint8(SFTPPacketType.version.rawValue)
        writer.uint32(3)
        return writer.data
    }

    static func status(_ id: UInt32, _ code: SFTPStatusCode, message: String = "") -> Data {
        var writer = SFTPWriter()
        writer.uint32(code.rawValue)
        writer.string(message)
        writer.string("")
        return SFTPFraming.frame(type: .status, id: id, payload: writer.bytes)
    }

    static func handle(_ id: UInt32, _ handle: [UInt8] = [0, 0, 0, 1]) -> Data {
        var writer = SFTPWriter()
        writer.rawData(handle)
        return SFTPFraming.frame(type: .handle, id: id, payload: writer.bytes)
    }

    static func data(_ id: UInt32, _ bytes: [UInt8]) -> Data {
        var writer = SFTPWriter()
        writer.rawData(bytes)
        return SFTPFraming.frame(type: .data, id: id, payload: writer.bytes)
    }

    static func names(_ id: UInt32, _ entries: [(String, SFTPAttributes)]) -> Data {
        var writer = SFTPWriter()
        writer.uint32(UInt32(entries.count))
        for (name, attrs) in entries {
            writer.string(name)
            writer.string(name)
            writer.attributes(attrs)
        }
        return SFTPFraming.frame(type: .name, id: id, payload: writer.bytes)
    }

    static func attrs(_ id: UInt32, _ attributes: SFTPAttributes) -> Data {
        var writer = SFTPWriter()
        writer.attributes(attributes)
        return SFTPFraming.frame(type: .attrs, id: id, payload: writer.bytes)
    }

    /// The request id of a client packet.
    static func id(of packet: [UInt8]) -> UInt32 {
        var reader = SFTPReader(Array(packet.dropFirst(4)))
        _ = try? reader.uint8()
        return (try? reader.uint32()) ?? 0
    }

    static func type(of packet: [UInt8]) -> SFTPPacketType? {
        var reader = SFTPReader(Array(packet.dropFirst(4)))
        guard let raw = try? reader.uint8() else { return nil }
        return SFTPPacketType(rawValue: raw)
    }
}

final class SFTPClientTests: XCTestCase {

    private func makeClient(
        transport: FakeSFTPTransport,
        elevation: ElevationProvider? = nil
    ) -> SFTPClient {
        SFTPClient(transport: transport, elevation: elevation)
    }

    private func connect(_ client: SFTPClient, _ transport: FakeSFTPTransport) async throws {
        transport.onRequest = { packet in
            FakeServer.type(of: packet) == .initPacket ? [FakeServer.version()] : []
        }
        try await client.connect()
    }

    // MARK: - Handshake

    func testConnectExchangesVersions() async throws {
        let transport = FakeSFTPTransport()
        let client = makeClient(transport: transport)
        try await connect(client, transport)
        XCTAssertEqual(client.version, 3)
        XCTAssertEqual(transport.requestType(at: 0), .initPacket)
    }

    func testRequestBeforeConnectThrows() async {
        let client = makeClient(transport: FakeSFTPTransport())
        do {
            _ = try await client.list("/tmp")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is SFTPError)
        }
    }

    // MARK: - Listing

    func testListDecodesEntriesAndDropsDotEntries() async throws {
        let transport = FakeSFTPTransport()
        let client = makeClient(transport: transport)
        try await connect(client, transport)

        transport.onRequest = { packet in
            let id = FakeServer.id(of: packet)
            switch FakeServer.type(of: packet) {
            case .opendir:
                return [FakeServer.handle(id)]
            case .readdir:
                // One entry set, then EOF.
                if transport.written.filter({ FakeServer.type(of: $0) == .readdir }).count == 1 {
                    return [FakeServer.names(id, [
                        (".", SFTPAttributes(permissions: 0o040755)),
                        ("..", SFTPAttributes(permissions: 0o040755)),
                        ("notes.txt", SFTPAttributes(size: 12, permissions: 0o100644)),
                        ("sub", SFTPAttributes(size: 0, permissions: 0o040755)),
                    ])]
                }
                return [FakeServer.status(id, .eof)]
            case .close:
                return [FakeServer.status(id, .ok)]
            default:
                return []
            }
        }

        let entries = try await client.list("/home/u")
        XCTAssertEqual(entries.map(\.name), ["sub", "notes.txt"])   // directories first
        XCTAssertEqual(entries.first?.path, "/home/u/sub")
        XCTAssertEqual(entries.last?.size, 12)
        XCTAssertTrue(entries.first!.isDirectory)
    }

    func testListSurfacesAPermissionError() async throws {
        let transport = FakeSFTPTransport()
        let client = makeClient(transport: transport)
        try await connect(client, transport)
        transport.onRequest = { [weak transport] packet in
            _ = transport
            return [FakeServer.status(FakeServer.id(of: packet), .permissionDenied, message: "Permission denied.")]
        }
        do {
            _ = try await client.list("/root")
            XCTFail("expected a permission error")
        } catch let error as SFTPError {
            guard case .status(let code, let message) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(code, .permissionDenied)
            XCTAssertEqual(message, "Permission denied.")
        }
    }

    // MARK: - Read / write

    func testReadFileStreamsUntilEOF() async throws {
        let transport = FakeSFTPTransport()
        let client = makeClient(transport: transport)
        try await connect(client, transport)

        let payload = Array("hello world".utf8)
        transport.onRequest = { packet in
            let id = FakeServer.id(of: packet)
            switch FakeServer.type(of: packet) {
            case .stat:
                return [FakeServer.attrs(id, SFTPAttributes(size: UInt64(payload.count), permissions: 0o100644))]
            case .open:
                return [FakeServer.handle(id)]
            case .read:
                // Two reads: the payload, then EOF.
                let reads = transport.written.filter { FakeServer.type(of: $0) == .read }.count
                return reads == 1
                    ? [FakeServer.data(id, Array(payload.prefix(5)))]
                    : (reads == 2 ? [FakeServer.data(id, Array(payload.dropFirst(5)))]
                                  : [FakeServer.status(id, .eof)])
            case .close:
                return [FakeServer.status(id, .ok)]
            default:
                return []
            }
        }

        let data = try await client.readFile("/tmp/a.txt")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "hello world")
    }

    func testWriteFileChunksAndOpensForTruncate() async throws {
        let transport = FakeSFTPTransport()
        let client = makeClient(transport: transport)
        try await connect(client, transport)

        var openedFlags: UInt32 = 0
        transport.onRequest = { packet in
            let id = FakeServer.id(of: packet)
            switch FakeServer.type(of: packet) {
            case .open:
                var reader = SFTPReader(Array(packet.dropFirst(9)))
                _ = try? reader.string()
                openedFlags = (try? reader.uint32()) ?? 0
                return [FakeServer.handle(id)]
            case .write, .close:
                return [FakeServer.status(id, .ok)]
            default:
                return []
            }
        }

        let blob = Data(repeating: 0x41, count: 1000)
        try await client.writeFile("/tmp/out.bin", data: blob)

        XCTAssertEqual(openedFlags & SFTPOpenFlags.trunc.rawValue, SFTPOpenFlags.trunc.rawValue)
        XCTAssertEqual(openedFlags & SFTPOpenFlags.creat.rawValue, SFTPOpenFlags.creat.rawValue)
        XCTAssertEqual(transport.written.filter { FakeServer.type(of: $0) == .write }.count, 1)
    }

    // MARK: - Mutations

    func testMkdirRenameRemoveAndChmod() async throws {
        let transport = FakeSFTPTransport()
        let client = makeClient(transport: transport)
        try await connect(client, transport)
        transport.onRequest = { packet in
            [FakeServer.status(FakeServer.id(of: packet), .ok)]
        }

        try await client.mkdir("/tmp/new")
        try await client.rename("/tmp/new", to: "/tmp/renamed")
        try await client.remove("/tmp/renamed")
        try await client.rmdir("/tmp")
        try await client.setPermissions("/tmp/x", permissions: 0o640)

        let types = transport.written.compactMap { FakeServer.type(of: $0) }
        XCTAssertEqual(types, [.initPacket, .mkdir, .rename, .remove, .rmdir, .setstat])
    }

    func testStatPrefersLstatWhenAsked() async throws {
        let transport = FakeSFTPTransport()
        let client = makeClient(transport: transport)
        try await connect(client, transport)
        transport.onRequest = { packet in
            [FakeServer.attrs(FakeServer.id(of: packet), SFTPAttributes(size: 7, permissions: 0o120777))]
        }
        let attrs = try await client.stat("/tmp/link", followSymlinks: false)
        XCTAssertTrue(attrs.isSymlink)
        XCTAssertEqual(transport.requestType(at: 1), .lstat)
    }

    // MARK: - Elevation

    /// The behaviour card 6 depends on: a permission failure retries the *same*
    /// operation once on the elevated transport instead of giving up.
    func testPermissionDeniedIsRetriedOnTheElevatedTransport() async throws {
        let normal = FakeSFTPTransport()
        let elevated = FakeSFTPTransport()

        // The normal transport refuses; the elevated one succeeds.
        normal.onRequest = { packet in
            FakeServer.type(of: packet) == .initPacket
                ? [FakeServer.version()]
                : [FakeServer.status(FakeServer.id(of: packet), .permissionDenied, message: "denied")]
        }
        elevated.onRequest = { packet in
            FakeServer.type(of: packet) == .initPacket
                ? [FakeServer.version()]
                : [FakeServer.status(FakeServer.id(of: packet), .ok)]
        }

        let provider = FakeElevation { path in
            XCTAssertEqual(path, "/etc/secure")
            return elevated
        }
        let client = makeClient(transport: normal, elevation: provider)
        try await client.connect()

        try await client.mkdir("/etc/secure")
        XCTAssertEqual(elevated.written.compactMap { FakeServer.type(of: $0) }, [.initPacket, .mkdir])
        XCTAssertEqual(provider.requests, ["/etc/secure"])
    }

    func testWithoutAnElevationProviderTheErrorIsSurfaced() async throws {
        let normal = FakeSFTPTransport()
        normal.onRequest = { packet in
            FakeServer.type(of: packet) == .initPacket
                ? [FakeServer.version()]
                : [FakeServer.status(FakeServer.id(of: packet), .permissionDenied)]
        }
        let client = makeClient(transport: normal)
        try await client.connect()
        do {
            try await client.mkdir("/etc/secure")
            XCTFail("expected a permission error")
        } catch let error as SFTPError {
            guard case .status(let code, _) = error else { return XCTFail("wrong error \(error)") }
            XCTAssertEqual(code, .permissionDenied)
        }
    }

    func testElevationIsAttemptedOnlyOnceSoABadPasswordCannotLoop() async throws {
        let normal = FakeSFTPTransport()
        let elevated = FakeSFTPTransport()
        normal.onRequest = { packet in
            FakeServer.type(of: packet) == .initPacket
                ? [FakeServer.version()]
                : [FakeServer.status(FakeServer.id(of: packet), .permissionDenied)]
        }
        elevated.onRequest = { packet in
            FakeServer.type(of: packet) == .initPacket
                ? [FakeServer.version()]
                : [FakeServer.status(FakeServer.id(of: packet), .permissionDenied)]
        }
        let provider = FakeElevation { _ in elevated }
        let client = makeClient(transport: normal, elevation: provider)
        try await client.connect()

        do {
            try await client.mkdir("/etc/secure")
            XCTFail("expected a permission error")
        } catch {
            // Exactly one elevation attempt: the retry lands on the elevated
            // client, which is already marked, so a wrong password or a missing
            // sudoers entry surfaces instead of looping.
            XCTAssertEqual(provider.requests.count, 1)
        }
    }

    // MARK: - Paths

    func testPathNormalisation() {
        XCTAssertEqual(SFTPClient.normalise("/a/b/../c"), "/a/c")
        XCTAssertEqual(SFTPClient.normalise("/a/./b/"), "/a/b")
        XCTAssertEqual(SFTPClient.normalise("/../..//x"), "/x")
        XCTAssertEqual(SFTPClient.normalise("/"), "/")
        XCTAssertEqual(SFTPClient.normalise("a/b"), "a/b")
        XCTAssertEqual(SFTPClient.join("/", "x"), "/x")
        XCTAssertEqual(SFTPClient.join("/a", "b"), "/a/b")
        XCTAssertEqual(SFTPClient.parent(of: "/a/b"), "/a")
        XCTAssertEqual(SFTPClient.parent(of: "/a"), "/")
        XCTAssertEqual(SFTPClient.parent(of: "/"), "/")
    }

    func testRealpathReturnsTheServerPath() async throws {
        let transport = FakeSFTPTransport()
        let client = makeClient(transport: transport)
        try await connect(client, transport)
        transport.onRequest = { packet in
            [FakeServer.names(FakeServer.id(of: packet), [("/real/home", SFTPAttributes(permissions: 0o040755))])]
        }
        let path = try await client.realpath("~/x")
        XCTAssertEqual(path, "/real/home")
    }
}

/// Records what the client asked to elevate.
final class FakeElevation: ElevationProvider, @unchecked Sendable {
    private(set) var requests: [String] = []
    private let make: (String) -> SFTPTransport?

    init(_ make: @escaping (String) -> SFTPTransport?) { self.make = make }

    func elevatedTransport(for path: String) async -> SFTPTransport? {
        requests.append(path)
        return make(path)
    }
}
