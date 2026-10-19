import XCTest
@testable import KRemoteCore

/// Live proof against a real server. Skipped unless `KMREMOTE_LIVE_ELEVATION=1`,
/// so CI never needs a machine or a password.
///
/// Run with:
///   KMREMOTE_LIVE_ELEVATION=1 \
///   KMREMOTE_LIVE_HOST=127.0.0.1 KMREMOTE_LIVE_PORT=2222 \
///   KMREMOTE_LIVE_USER=krtest KMREMOTE_LIVE_KEY=/path/key \
///   KMREMOTE_LIVE_PASSWORD=... KMREMOTE_LIVE_PATH=/root/root-owned.txt \
///   swift test --filter LiveElevationTests
///
/// The password arrives through the environment, is never written to a file, and
/// is never printed — it goes straight into an in-memory secret store.
final class LiveElevationTests: XCTestCase {

    private var env: [String: String] { ProcessInfo.processInfo.environment }

    private func required(_ name: String) throws -> String {
        guard let value = env[name], !value.isEmpty else {
            throw XCTSkip("\(name) is not set")
        }
        return value
    }

    func testLiveElevationUnlocksARootOwnedPath() async throws {
        guard env["KMREMOTE_LIVE_ELEVATION"] == "1" else {
            throw XCTSkip("set KMREMOTE_LIVE_ELEVATION=1 to run the live proof")
        }
        let host = try required("KMREMOTE_LIVE_HOST")
        let portString = try required("KMREMOTE_LIVE_PORT")
        let port = try XCTUnwrap(Int(portString))
        let user = try required("KMREMOTE_LIVE_USER")
        let key = try required("KMREMOTE_LIVE_KEY")
        let password = try required("KMREMOTE_LIVE_PASSWORD")
        let path = try required("KMREMOTE_LIVE_PATH")
        let nodeID = UUID()

        let secrets = InMemorySecretStore()
        try secrets.setSecret(password, for: nodeID)

        // The plain channel, as the login user has it.
        let transport = ProcessSFTPTransport(
            host: host, port: port, username: user, identityFile: key
        )
        let provider = SudoElevationProvider(
            target: SudoTarget(
                nodeID: nodeID,
                host: host,
                port: port,
                username: user,
                identityFile: key,
                usesSudo: true
            ),
            secretStore: secrets
        )
        let client = SFTPClient(transport: transport, elevation: provider)
        try await client.connect()
        defer { client.disconnect() }

        print("LIVE: connected, protocol version \(client.version) over `ssh -T -s sftp`")

        // 1. Prove the login user really lacks the right: a client *without* an
        //    elevation provider must be refused. Without this the success below
        //    would prove nothing.
        let plainClient = SFTPClient(
            transport: ProcessSFTPTransport(host: host, port: port, username: user, identityFile: key)
        )
        try await plainClient.connect()
        do {
            try await plainClient.setPermissions(path, permissions: 0o640)
            plainClient.disconnect()
            XCTFail("the login user could chmod \(path); pick a root-owned path")
        } catch SFTPError.status(let code, let message) {
            XCTAssertEqual(code, .permissionDenied)
            print("LIVE: unprivileged chmod refused — \(message)")
        }
        plainClient.disconnect()

        // 2. The same operation through the client must succeed after exactly one
        //    elevated connection.
        let started = Date()
        try await client.setPermissions(path, permissions: 0o640)
        print("LIVE: elevated chmod succeeded in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")

        // 3. Read it back over the *same* base channel to prove the change landed
        //    and that the base channel is still the one being used.
        let attributes = try await client.stat(path)
        XCTAssertEqual(attributes.modeBits & 0o777, 0o640)
        print("LIVE: stat over the base channel now reports mode \(String(attributes.modeBits & 0o777, radix: 8))")
    }

    /// A wrong stored password must produce one `elevationFailed` carrying sudo's
    /// own text, and no repeat attempt.
    func testLiveWrongPasswordProducesOneTypedError() async throws {
        guard env["KMREMOTE_LIVE_ELEVATION"] == "1" else {
            throw XCTSkip("set KMREMOTE_LIVE_ELEVATION=1 to run the live proof")
        }
        let host = try required("KMREMOTE_LIVE_HOST")
        let port = try XCTUnwrap(Int(try required("KMREMOTE_LIVE_PORT")))
        let user = try required("KMREMOTE_LIVE_USER")
        let key = try required("KMREMOTE_LIVE_KEY")
        let path = try required("KMREMOTE_LIVE_PATH")
        let nodeID = UUID()
        let wrong = "definitely-not-the-password"

        let secrets = InMemorySecretStore()
        try secrets.setSecret(wrong, for: nodeID)

        let transport = ProcessSFTPTransport(
            host: host, port: port, username: user, identityFile: key
        )
        let provider = SudoElevationProvider(
            target: SudoTarget(
                nodeID: nodeID, host: host, port: port,
                username: user, identityFile: key, usesSudo: true
            ),
            secretStore: secrets
        )
        let client = SFTPClient(transport: transport, elevation: provider)
        try await client.connect()
        defer { client.disconnect() }

        let started = Date()
        do {
            try await client.setPermissions(path, permissions: 0o600)
            XCTFail("a wrong password must not succeed")
        } catch SFTPError.elevationFailed(let failure) {
            let elapsed = Date().timeIntervalSince(started)
            print("LIVE: wrong password → kind=\(failure.kind.rawValue) after \(String(format: "%.2f", elapsed))s")
            print("LIVE: sudo said: \(failure.stderr)")
            XCTAssertEqual(failure.kind, .passwordRejected)
            XCTAssertFalse(failure.stderr.isEmpty, "sudo's own message must survive")
            XCTAssertFalse(failure.stderr.contains(wrong), "the password must never appear in the error")
            // One attempt: a refusal must not take long enough to look like two.
            XCTAssertLessThan(elapsed, 10, "one attempt, not a retry loop")
            let alert = (SFTPError.elevationFailed(failure) as LocalizedError).errorDescription ?? ""
            XCTAssertFalse(alert.contains(wrong))
            XCTAssertTrue(alert.contains("sudo"))
        }
    }
}
