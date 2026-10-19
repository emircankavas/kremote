import XCTest
@testable import KRemoteCore

/// End-to-end wiring: a real `SudoElevationProvider` behind a real `SFTPClient`,
/// with scripted transports standing in for the plain and elevated channels.
///
/// These are the five cases card 6 calls out. No server is involved, so they run
/// in CI.
final class SFTPElevationIntegrationTests: XCTestCase {

    private let nodeID = UUID()
    private let password = "correct horse battery staple"

    private func store(_ value: String?) -> InMemorySecretStore {
        let store = InMemorySecretStore()
        if let value { try? store.setSecret(value, for: nodeID) }
        return store
    }

    /// A plain channel that always refuses mutations, like a login user without
    /// write rights on a root-owned file.
    private func refudingTransport() -> FakeSFTPTransport {
        let transport = FakeSFTPTransport()
        transport.onRequest = { packet in
            FakeServer.type(of: packet) == .initPacket
                ? [FakeServer.version()]
                : [FakeServer.status(FakeServer.id(of: packet), .permissionDenied, message: "Permission denied.")]
        }
        return transport
    }

    /// An elevated channel that accepts everything.
    private func acceptingTransport() -> FakeSFTPTransport {
        let transport = FakeSFTPTransport()
        transport.onRequest = { packet in
            FakeServer.type(of: packet) == .initPacket
                ? [FakeServer.version()]
                : [FakeServer.status(FakeServer.id(of: packet), .ok)]
        }
        return transport
    }

    /// Counts how many elevated connections the provider opened — the thing the
    /// acceptance criteria measure as "exactly one per operation".
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    private func makeClient(
        base: FakeSFTPTransport,
        usesSudo: Bool,
        password stored: String?,
        elevated: FakeSFTPTransport?,
        counter: Counter
    ) -> SFTPClient {
        let provider = SudoElevationProvider(
            target: SudoTarget(nodeID: nodeID, host: "h", usesSudo: usesSudo),
            secretStore: store(stored),
            timeouts: ElevationTimeouts(setup: 1, firstResponse: 1, settle: 0.05)
        ) { _, _ in
            counter.bump()
            // A scripted plain transport: the provider's contract only needs a
            // transport that is already running as root.
            return elevated ?? FakeSFTPTransport()
        }
        return SFTPClient(transport: base, elevation: provider)
    }

    // 1. permission denied + password + sudo flag → exactly one elevated retry,
    //    and the operation succeeds.
    func testPermissionDeniedWithPasswordAndFlagRetriesOnceAndSucceeds() async throws {
        let base = refudingTransport()
        let elevated = acceptingTransport()
        let counter = Counter()
        let client = makeClient(
            base: base, usesSudo: true, password: password, elevated: elevated, counter: counter
        )
        try await client.connect()

        try await client.setPermissions("/root/owned.txt", permissions: 0o644)

        XCTAssertEqual(counter.count, 1, "one elevated connection for one refused operation")
        XCTAssertEqual(
            elevated.written.compactMap { FakeServer.type(of: $0) },
            [.initPacket, .setstat]
        )
        // The base channel did the first attempt and was not replaced.
        XCTAssertEqual(base.written.compactMap { FakeServer.type(of: $0) }, [.initPacket, .setstat])
    }

    // 2. no sudo flag → the original error surfaces and nothing is attempted.
    func testWithoutTheSudoFlagTheOriginalErrorSurfacesAndNothingIsRetried() async throws {
        let base = refudingTransport()
        let counter = Counter()
        let client = makeClient(
            base: base, usesSudo: false, password: password, elevated: nil, counter: counter
        )
        try await client.connect()

        do {
            try await client.setPermissions("/root/owned.txt", permissions: 0o644)
            XCTFail("expected permissionDenied")
        } catch SFTPError.status(let code, let message) {
            XCTAssertEqual(code, .permissionDenied)
            XCTAssertEqual(message, "Permission denied.")
        }
        XCTAssertEqual(counter.count, 0, "no elevated connection may be opened")
    }

    // 3. the elevated attempt is refused too → one `elevationFailed`, exactly one
    //    retry, no loop.
    func testRefusedElevatedAttemptProducesOneElevationFailedAndOneRetry() async throws {
        let base = refudingTransport()
        let elevatedRefusing = refudingTransport()
        let counter = Counter()
        let client = makeClient(
            base: base, usesSudo: true, password: password, elevated: elevatedRefusing, counter: counter
        )
        try await client.connect()

        do {
            try await client.setPermissions("/root/owned.txt", permissions: 0o644)
            XCTFail("expected an elevation failure")
        } catch SFTPError.elevationFailed(let failure) {
            XCTAssertTrue(failure.stderr.contains("Permission denied."))
            XCTAssertEqual(failure.kind, .unknown, "an SFTP refusal is not a sudo message")
        }
        XCTAssertEqual(counter.count, 1, "exactly one elevated attempt, never a loop")
        // The elevated channel carried the handshake and one attempt — not two.
        XCTAssertEqual(
            elevatedRefusing.written.compactMap { FakeServer.type(of: $0) },
            [.initPacket, .setstat]
        )
    }

    // 4. no stored password → no attempt at all.
    func testMissingPasswordMeansNoAttempt() async throws {
        let base = refudingTransport()
        let counter = Counter()
        let client = makeClient(
            base: base, usesSudo: true, password: nil, elevated: nil, counter: counter
        )
        try await client.connect()

        do {
            try await client.setPermissions("/root/owned.txt", permissions: 0o644)
            XCTFail("expected permissionDenied")
        } catch SFTPError.status(let code, _) {
            XCTAssertEqual(code, .permissionDenied)
        }
        XCTAssertEqual(counter.count, 0)
    }

    // 4b. a blank/unsendable password counts as missing.
    func testBlankPasswordMeansNoAttempt() async throws {
        for bad in ["", "   ", "line\nbreak"] {
            let base = refudingTransport()
            let counter = Counter()
            let client = makeClient(
                base: base, usesSudo: true, password: bad, elevated: nil, counter: counter
            )
            try await client.connect()
            _ = try? await client.setPermissions("/root/owned.txt", permissions: 0o644)
            XCTAssertEqual(counter.count, 0, "\(bad.debugDescription) must not elevate")
        }
    }

    // 5. a sudo refusal on the elevated channel surfaces as its own typed error,
    //    carries sudo's text, and is attempted once.
    func testSudoRefusalSurfacesSudosMessageOnce() async throws {
        let base = refudingTransport()
        let counter = Counter()
        let elevatedProcess = FakeElevatedProcess()
        elevatedProcess.stderrAfterWrite = "sudo: 3 incorrect password attempts\n"

        let provider = SudoElevationProvider(
            target: SudoTarget(nodeID: nodeID, host: "h", usesSudo: true),
            secretStore: store("wrong-password"),
            timeouts: ElevationTimeouts(setup: 1, firstResponse: 1, settle: 0.05)
        ) { _, line in
            counter.bump()
            return SudoSFTPTransport(
                process: elevatedProcess,
                passwordLine: line,
                timeouts: ElevationTimeouts(setup: 1, firstResponse: 1, settle: 0.05)
            )
        }
        let client = SFTPClient(transport: base, elevation: provider)
        try await client.connect()

        do {
            try await client.setPermissions("/root/owned.txt", permissions: 0o644)
            XCTFail("expected an elevation failure")
        } catch SFTPError.elevationFailed(let failure) {
            XCTAssertTrue(failure.stderr.contains("incorrect password"))
            XCTAssertEqual(failure.kind, .passwordRejected)
            XCTAssertFalse(failure.stderr.contains("wrong-password"))
            XCTAssertFalse(failure.kind.userFacingMessage.contains("wrong-password"))
        }
        XCTAssertEqual(counter.count, 1)
        // The secret never reaches the base channel either.
        XCTAssertFalse(base.stderrText().contains("wrong-password"))
    }

    // Elevation is per operation: a second refused operation elevates again, on a
    // fresh connection, rather than switching the client into a privileged mode.
    func testElevationIsPerOperationNotAPersistentMode() async throws {
        let base = refudingTransport()
        let firstElevated = acceptingTransport()
        let secondElevated = acceptingTransport()
        let counter = Counter()
        var nextTransport: FakeSFTPTransport = firstElevated

        let provider = SudoElevationProvider(
            target: SudoTarget(nodeID: nodeID, host: "h", usesSudo: true),
            secretStore: store(password),
            timeouts: ElevationTimeouts(setup: 1, firstResponse: 1, settle: 0.05)
        ) { _, _ in
            counter.bump()
            defer { nextTransport = secondElevated }
            return nextTransport
        }
        let client = SFTPClient(transport: base, elevation: provider)
        try await client.connect()

        try await client.setPermissions("/root/a", permissions: 0o600)
        try await client.setPermissions("/root/b", permissions: 0o600)

        XCTAssertEqual(counter.count, 2, "each operation pays for its own elevated connection")
        // Both operations on the base channel — it never became privileged.
        XCTAssertEqual(
            base.written.compactMap { FakeServer.type(of: $0) },
            [.initPacket, .setstat, .setstat]
        )
    }
}
