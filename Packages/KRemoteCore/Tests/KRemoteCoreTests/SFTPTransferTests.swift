import XCTest
@testable import KRemoteCore

/// The streaming transfer engine, driven by the scripted transport from
/// `SFTPClientTests`. These cover the two promises the card makes that are
/// testable without a server: a transfer only appears under its real name once it
/// is complete, and a cancelled one leaves no `.part` behind.
final class SFTPTransferTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kremote-transfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    /// A server that serves `payload` in `chunkSize` READ replies, then EOF.
    private func servingTransport(payload: [UInt8], chunkSize: Int) -> FakeSFTPTransport {
        let transport = FakeSFTPTransport()
        var served = 0
        transport.onRequest = { packet in
            let id = FakeServer.id(of: packet)
            switch FakeServer.type(of: packet) {
            case .initPacket:
                return [FakeServer.version()]
            case .stat:
                return [FakeServer.attrs(id, SFTPAttributes(
                    size: UInt64(payload.count), permissions: 0o100644
                ))]
            case .open, .close:
                return FakeServer.type(of: packet) == .open
                    ? [FakeServer.handle(id)]
                    : [FakeServer.status(id, .ok)]
            case .read:
                if served >= payload.count { return [FakeServer.status(id, .eof)] }
                let end = min(served + chunkSize, payload.count)
                let chunk = Array(payload[served..<end])
                served = end
                return [FakeServer.data(id, chunk)]
            default:
                return [FakeServer.status(id, .ok)]
            }
        }
        return transport
    }

    private func connectedClient(_ transport: FakeSFTPTransport) async throws -> SFTPClient {
        let client = SFTPClient(transport: transport)
        try await client.connect()
        return client
    }

    // MARK: - Download

    func testDownloadWritesOnlyTheFinalNameAndMatchesTheBytes() async throws {
        let payload = Array("hello streaming world".utf8)
        let transport = servingTransport(payload: payload, chunkSize: 5)
        let client = try await connectedClient(transport)

        let target = scratch.appendingPathComponent("out.txt")
        let written = try await client.downloadFile("/remote/out.txt", to: target)

        XCTAssertEqual(written, Int64(payload.count))
        XCTAssertEqual(try Data(contentsOf: target), Data(payload))
        // The .part file must be gone, and nothing else may be left in the folder.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
        XCTAssertEqual(leftovers, ["out.txt"])
    }

    func testDownloadReportsMonotonicProgress() async throws {
        let payload = Array(repeating: UInt8(0x41), count: 100)
        let transport = servingTransport(payload: payload, chunkSize: 10)
        let client = try await connectedClient(transport)

        let recorder = ProgressRecorder()
        _ = try await client.downloadFile(
            "/remote/a.bin",
            to: scratch.appendingPathComponent("a.bin"),
            progress: { recorder.record($0) }
        )

        let ticks = recorder.ticks
        XCTAssertFalse(ticks.isEmpty)
        XCTAssertEqual(ticks.map(\.bytesDone), ticks.map(\.bytesDone).sorted())
        XCTAssertEqual(ticks.last?.bytesDone, 100)
        XCTAssertTrue(ticks.allSatisfy { $0.bytesTotal == 100 })
    }

    /// Cancel after the first chunk: the handle is closed, the `.part` is removed
    /// and no file appears under the real name.
    func testCancelledDownloadLeavesNoPartAndNoTarget() async throws {
        let payload = Array(repeating: UInt8(0x42), count: 500)
        let transport = servingTransport(payload: payload, chunkSize: 10)
        let client = try await connectedClient(transport)

        let target = scratch.appendingPathComponent("cancelled.bin")
        let seen = ProgressRecorder()
        do {
            _ = try await client.downloadFile(
                "/remote/big.bin",
                to: target,
                progress: { tick in
                    seen.record(tick)
                    // Stop as soon as anything has landed.
                    if tick.bytesDone >= 10 { seen.cancel() }
                },
                isCancelled: { seen.isCancelled }
            )
            XCTFail("expected the transfer to be cancelled")
        } catch {
            XCTAssertTrue(error is TransferCancelled)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: SFTPClient.partURL(for: target).path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
        XCTAssertTrue(leftovers.isEmpty, "left behind: \(leftovers)")

        // CLOSE must have reached the server: a handle held open is a leak on the
        // remote side even when the local file is cleaned up.
        let types = transport.written.compactMap { FakeServer.type(of: $0) }
        XCTAssertTrue(types.contains(.close))
    }

    // MARK: - Upload

    func testUploadWritesAPartNameThenRenamesIntoPlace() async throws {
        let transport = FakeSFTPTransport()
        var openedPaths: [String] = []
        var renamedFrom: String?
        var renamedTo: String?
        transport.onRequest = { packet in
            let id = FakeServer.id(of: packet)
            switch FakeServer.type(of: packet) {
            case .initPacket: return [FakeServer.version()]
            case .open:
                var reader = SFTPReader(Array(packet.dropFirst(9)))
                openedPaths.append((try? reader.string()) ?? "")
                return [FakeServer.handle(id)]
            case .rename:
                var reader = SFTPReader(Array(packet.dropFirst(9)))
                renamedFrom = try? reader.string()
                renamedTo = try? reader.string()
                return [FakeServer.status(id, .ok)]
            default:
                return [FakeServer.status(id, .ok)]
            }
        }
        let client = try await connectedClient(transport)

        let source = scratch.appendingPathComponent("local.txt")
        try Data(repeating: 0x43, count: 1000).write(to: source)

        _ = try await client.uploadFile(source, to: "/srv/local.txt")

        // The bytes went to a hidden .part name; the real name appeared via RENAME.
        XCTAssertEqual(openedPaths, ["/srv/.local.txt.part"])
        XCTAssertEqual(renamedFrom, "/srv/.local.txt.part")
        XCTAssertEqual(renamedTo, "/srv/local.txt")
    }

    func testCancelledUploadRemovesTheRemotePart() async throws {
        let transport = FakeSFTPTransport()
        var removed: [String] = []
        transport.onRequest = { packet in
            let id = FakeServer.id(of: packet)
            switch FakeServer.type(of: packet) {
            case .initPacket: return [FakeServer.version()]
            case .open: return [FakeServer.handle(id)]
            case .remove:
                var reader = SFTPReader(Array(packet.dropFirst(9)))
                removed.append((try? reader.string()) ?? "")
                return [FakeServer.status(id, .ok)]
            default: return [FakeServer.status(id, .ok)]
            }
        }
        let client = try await connectedClient(transport)

        let source = scratch.appendingPathComponent("local.bin")
        try Data(repeating: 0x44, count: 200_000).write(to: source)

        do {
            _ = try await client.uploadFile(source, to: "/srv/local.bin", isCancelled: { true })
            XCTFail("expected the upload to be cancelled")
        } catch {
            XCTAssertTrue(error is TransferCancelled)
        }
        XCTAssertEqual(removed, ["/srv/.local.bin.part"])
    }

    func testUploadOfAFileThatDoesNotExistFailsBeforeTouchingTheServer() async throws {
        let transport = FakeSFTPTransport()
        transport.onRequest = { _ in [FakeServer.version()] }
        let client = try await connectedClient(transport)

        do {
            _ = try await client.uploadFile(
                scratch.appendingPathComponent("missing.txt"), to: "/srv/x.txt"
            )
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is CocoaError || error is NSError)
        }
        // Nothing but the handshake was written.
        XCTAssertEqual(transport.requestType(at: 1), nil)
    }

    // MARK: - Recursive count

    /// The delete confirmation derives its "it contains N items" from this number
    /// by subtracting the folder itself. A folder holding two files must therefore
    /// report 3 — the number `removeRecursively` removes — not 2.
    func testCountItemsIncludesTheFolderItself() async throws {
        let transport = FakeSFTPTransport()

        // The root is the first thing stat'd and is a directory; the children
        // after it are plain files, so the walk stops at depth one.
        let stats = Counter()
        let listings = Counter()
        transport.onRequest = { packet in
            let id = FakeServer.id(of: packet)
            switch FakeServer.type(of: packet) {
            case .initPacket:
                return [FakeServer.version()]
            case .stat, .lstat:
                let isRoot = stats.increment() == 1
                return [FakeServer.attrs(id, SFTPAttributes(
                    permissions: isRoot ? 0o040755 : 0o100644
                ))]
            case .opendir:
                return [FakeServer.handle(id)]
            case .readdir:
                if listings.increment() == 1 {
                    return [FakeServer.names(id, [
                        ("a.txt", SFTPAttributes(size: 1, permissions: 0o100644)),
                        ("b.txt", SFTPAttributes(size: 1, permissions: 0o100644)),
                    ])]
                }
                return [FakeServer.status(id, .eof)]
            default:
                return [FakeServer.status(id, .ok)]
            }
        }

        let client = try await connectedClient(transport)
        let count = try await client.countItems(in: "/srv/tree")
        XCTAssertEqual(count, 3, "the folder itself must be included")
    }
}

/// A counter the scripted transport can bump from its own queue.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.withLock { value += 1; return value } }
}

/// Collects progress ticks from a `@Sendable` closure.
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TransferProgress] = []

    func record(_ tick: TransferProgress) {
        lock.withLock { storage.append(tick) }
    }

    var ticks: [TransferProgress] { lock.withLock { storage } }

    private var cancelledStorage = false
    func cancel() { lock.withLock { cancelledStorage = true } }
    var isCancelled: Bool { lock.withLock { cancelledStorage } }
}
