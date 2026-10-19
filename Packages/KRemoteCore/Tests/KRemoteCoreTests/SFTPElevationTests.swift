import XCTest
@testable import KRemoteCore

// MARK: - Scripted elevated process

/// Stands in for `ssh` + `sudo` on the elevation path.
///
/// Records exactly what was written — the password line and then the protocol
/// bytes — so a test can assert both that the password was sent *first and
/// alone* and that nothing else ever touched stdin.
final class FakeElevatedProcess: ElevatedProcess, @unchecked Sendable {
    /// Everything written to the child's stdin, in order.
    private(set) var written: [Data] = []
    /// What the child "wrote" to stderr before/while starting.
    private var stderr = ""
    /// What the child "wrote" to stdout, served as reads.
    private var stdoutQueue: [Data] = []
    /// When true, a read blocks forever — the "server swallowed stdin" case.
    var hangsOnRead = false
    /// When true, `open()` never returns — the "ssh never came up" case.
    var hangsOnOpen = false
    /// When set, `open()` throws this (ssh missing, fork failure).
    var openError: Error?

    private let condition = NSCondition()
    private var closed = false

    init(stderr: String = "", stdout: [Data] = []) {
        self.stderr = stderr
        self.stdoutQueue = stdout
    }

    /// Text that is only revealed after the password line was written — the
    /// normal shape of a sudo refusal.
    var stderrAfterWrite: String?

    var openCount = 0

    func open() async throws {
        openCount += 1
        if hangsOnOpen {
            // Models a connection that is established but never answers: the
            // setup race must expire rather than block the caller.
            while condition.withLock({ !closed }) {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return
        }
        if let openError { throw openError }
    }

    func write(_ data: Data) throws {
        written.append(data)
        if let stderrAfterWrite, written.count >= 1 {
            condition.withLock { stderr = stderrAfterWrite }
        }
    }

    func read(maxLength: Int) throws -> Data? {
        if hangsOnRead {
            condition.withLock {
                while !closed { condition.wait(until: Date().addingTimeInterval(0.02)) }
            }
            return nil
        }
        return condition.withLock {
            guard !stdoutQueue.isEmpty else { return nil }
            return stdoutQueue.removeFirst()
        }
    }

    func stderrText() -> String { condition.withLock { stderr } }

    func close() {
        condition.withLock {
            closed = true
            condition.broadcast()
        }
    }

    var isAlive: Bool { condition.withLock { !closed } }

    /// The password line the transport was given, decoded for assertions.
    var firstWrite: String? {
        guard let first = written.first else { return nil }
        return String(decoding: first, as: UTF8.self)
    }
}

// MARK: - Tests

final class SFTPElevationTests: XCTestCase {

    private let nodeID = UUID()
    private let password = "s3cret-pässword"

    private func makeStore(_ value: String?) -> InMemorySecretStore {
        let store = InMemorySecretStore()
        if let value { try? store.setSecret(value, for: nodeID) }
        return store
    }

    private func makeProvider(
        usesSudo: Bool,
        password stored: String?,
        process: FakeElevatedProcess,
        timeouts: ElevationTimeouts = ElevationTimeouts(setup: 2, firstResponse: 2, settle: 0.05)
    ) -> (SudoElevationProvider, () -> Void) {
        var captured: (String, Data)?
        let provider = SudoElevationProvider(
            target: SudoTarget(
                nodeID: nodeID,
                host: "example.test",
                port: 22,
                username: "u",
                identityFile: "",
                usesSudo: usesSudo
            ),
            secretStore: makeStore(stored),
            timeouts: timeouts
        ) { command, line in
            captured = (command, line)
            return SudoSFTPTransport(process: process, passwordLine: line, timeouts: timeouts)
        }
        return (provider, { _ = captured })
    }

    // MARK: Command

    func testRemoteCommandRunsSudoWithStdoutPasswordAndPathDetection() {
        let command = ElevationCommand.remoteCommand
        XCTAssertTrue(command.contains("sudo -S -p ''"))
        XCTAssertTrue(command.hasSuffix("exec sudo -S -p '' \"$p\""))
        // Both platform layouts are probed, PATH is the fallback, sshd_config the
        // last resort — never a hard-coded single path.
        XCTAssertTrue(command.contains("/usr/libexec/sftp-server"))
        XCTAssertTrue(command.contains("/usr/lib/openssh/sftp-server"))
        XCTAssertTrue(command.contains("command -v sftp-server"))
        XCTAssertTrue(command.contains("sshd_config"))
        // A missing binary must say so on stderr rather than exit silently.
        XCTAssertTrue(command.contains("no sftp-server binary found") )
        // Nothing in the command may carry a password.
        XCTAssertFalse(command.contains(password))
    }

    // MARK: Password line

    func testPasswordIsWrittenFirstAsOneLineAndNeverAppearsInErrors() async throws {
        let process = FakeElevatedProcess(stdout: [FakeServer.version()])
        let (provider, _) = makeProvider(usesSudo: true, password: password, process: process)
        let producedTransport = await provider.elevatedTransport(for: "/etc/secret")
        let transport = try XCTUnwrap(producedTransport)
        try await transport.open()

        XCTAssertEqual(process.firstWrite, password + "\n")
        XCTAssertEqual(process.written.count, 1, "nothing but the password line may be written before the protocol")
        // Diagnostics never contain the secret.
        XCTAssertFalse(transport.stderrText().contains(password))
        if let sudo = transport as? SudoSFTPTransport {
            XCTAssertFalse(sudo.commandLine.joined(separator: " ").contains(password))
            XCTAssertTrue(sudo.didAuthenticate)
        }
        transport.close()
    }

    // MARK: Provider gating

    func testProviderReturnsNilWithoutTheSudoFlag() async {
        let process = FakeElevatedProcess()
        let (provider, _) = makeProvider(usesSudo: false, password: password, process: process)
        let transport = await provider.elevatedTransport(for: "/etc/secret")
        XCTAssertNil(transport)
        XCTAssertEqual(process.openCount, 0, "no connection may be attempted")
    }

    func testProviderReturnsNilWithoutAStoredPassword() async {
        let process = FakeElevatedProcess()
        let (provider, _) = makeProvider(usesSudo: true, password: nil, process: process)
        let transport = await provider.elevatedTransport(for: "/etc/secret")
        XCTAssertNil(transport)
        XCTAssertEqual(process.openCount, 0)
    }

    func testProviderReturnsNilForEmptyOrMultilinePasswords() async {
        let process = FakeElevatedProcess()
        for bad in ["", "   ", "two\nlines", "carriage\rreturn"] {
            let (provider, _) = makeProvider(usesSudo: true, password: bad, process: process)
            let transport = await provider.elevatedTransport(for: "/etc/secret")
            XCTAssertNil(transport, "password \(bad.debugDescription) must not produce an attempt")
        }
        XCTAssertEqual(process.openCount, 0)
    }

    func testShortPasswordIsStillUsable() {
        // A one-character password is a password: refusing it locally would break
        // a server that accepts it.
        XCTAssertTrue(SudoElevationProvider.isUsable(password: "a"))
        XCTAssertTrue(SudoElevationProvider.isUsable(password: password))
        XCTAssertFalse(SudoElevationProvider.isUsable(password: ""))
        XCTAssertFalse(SudoElevationProvider.isUsable(password: "\n"))
    }

    // MARK: The node flag

    func testUsesSudoFlagRoundTripsAndDefaultsToOff() throws {
        let node = ConnectionNode(kind: .connection, name: "web", host: "h")
        XCTAssertFalse(node.usesSudo, "a node never elevates unless it opted in")

        node.usesSudo = true
        let encoded = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(ConnectionNode.self, from: encoded)
        XCTAssertTrue(decoded.usesSudo)

        // An existing tree written before the flag existed must still load, with
        // elevation off and no password anywhere in the file.
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        json.removeValue(forKey: "usesSudo")
        let legacy = try JSONSerialization.data(withJSONObject: json)
        let loaded = try JSONDecoder().decode(ConnectionNode.self, from: legacy)
        XCTAssertFalse(loaded.usesSudo)
        XCTAssertEqual(loaded.id, node.id)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("usesSudo\":false"))

        // The draft carries it through the editor.
        let draft = ConnectionDraft(from: node)
        XCTAssertTrue(draft.usesSudo)
        XCTAssertEqual(ConnectionDraft(id: node.id, name: "web", usesSudo: true).usesSudo, true)
    }

    // MARK: Refusals are typed and classified

    func testWrongPasswordSurfacesSudosOwnWordsAsOneTypedError() async throws {
        let process = FakeElevatedProcess()
        process.stderrAfterWrite = "Sorry, try again.\nsudo: 1 incorrect password attempt\n"
        let (provider, _) = makeProvider(usesSudo: true, password: password, process: process)
        let producedTransport = await provider.elevatedTransport(for: "/etc/secret")
        let transport = try XCTUnwrap(producedTransport)

        do {
            try await transport.open()
            XCTFail("expected the refusal to surface")
        } catch SFTPError.elevationFailed(let failure) {
            XCTAssertEqual(failure.kind, .passwordRejected)
            XCTAssertTrue(failure.stderr.contains("Sorry, try again."))
            XCTAssertTrue(failure.stderr.contains("incorrect password attempt"))
            // The message the UI shows carries sudo's text and never the secret.
            let description = (SFTPError.elevationFailed(failure) as LocalizedError).errorDescription ?? ""
            XCTAssertTrue(description.contains("Sorry, try again."))
            XCTAssertFalse(description.contains(password))
        }
        XCTAssertEqual(process.openCount, 1, "exactly one connection per operation")
    }

    func testClassificationCoversEveryDistinguishableFailure() {
        XCTAssertEqual(
            ElevationFailureKind.classify(stderr: "sudo: a password is required"),
            .passwordRejected
        )
        XCTAssertEqual(
            ElevationFailureKind.classify(stderr: "Sorry, try again."),
            .passwordRejected
        )
        XCTAssertEqual(
            ElevationFailureKind.classify(
                stderr: "emircan is not in the sudoers file. This incident will be reported."
            ),
            .notPermitted
        )
        XCTAssertEqual(
            ElevationFailureKind.classify(stderr: "sudo: no tty present and no askpass program specified"),
            .terminalRequired
        )
        XCTAssertEqual(
            ElevationFailureKind.classify(stderr: "sudo: a terminal is required to read the password"),
            .terminalRequired
        )
        XCTAssertEqual(
            ElevationFailureKind.classify(
                stderr: "sftp-server: no sftp-server binary found (checked /usr/libexec, /usr/lib/openssh, PATH, sshd_config)"
            ),
            .sftpServerMissing
        )
        XCTAssertEqual(
            ElevationFailureKind.classify(stderr: "sudo: /usr/libexec/sftp-server: No such file or directory"),
            .sftpServerMissing
        )
        XCTAssertEqual(
            ElevationFailureKind.classify(stderr: "ssh: connect to host x port 22: Connection refused"),
            .connectionFailed
        )
        // Unknown wording still reaches the user; only the hint is lost.
        XCTAssertEqual(ElevationFailureKind.classify(stderr: "something new"), .unknown)
        XCTAssertEqual(ElevationFailureKind.classify(stderr: ""), .unknown)
    }

    func testNotPermittedAndMissingBinaryAreDistinctAlerts() {
        let notPermitted = ElevationFailure(stderr: "u is not in the sudoers file.")
        let missing = ElevationFailure(stderr: "sftp-server: no sftp-server binary found")
        XCTAssertNotEqual(notPermitted.kind, missing.kind)
        XCTAssertNotEqual(notPermitted.kind.userFacingMessage, missing.kind.userFacingMessage)
        XCTAssertEqual(notPermitted.kind, .notPermitted)
        XCTAssertEqual(missing.kind, .sftpServerMissing)
    }

    func testSshFailingAtStartupReportsItsStderr() async throws {
        let process = FakeElevatedProcess(stderr: "ssh: Could not resolve hostname example.test")
        process.openError = SFTPError.transport("ignored")
        let (provider, _) = makeProvider(usesSudo: true, password: password, process: process)
        let producedTransport = await provider.elevatedTransport(for: "/x")
        let transport = try XCTUnwrap(producedTransport)
        do {
            try await transport.open()
            XCTFail("expected a failure")
        } catch SFTPError.elevationFailed(let failure) {
            XCTAssertEqual(failure.kind, .connectionFailed)
            XCTAssertTrue(failure.stderr.contains("Could not resolve hostname"))
        }
        // No password is ever written when the connection never came up.
        XCTAssertEqual(process.written.count, 0)
    }

    // MARK: Hang protection

    func testSetupTimeoutFailsInsteadOfSpinning() async throws {
        let process = FakeElevatedProcess()
        process.hangsOnOpen = true
        let timeouts = ElevationTimeouts(setup: 0.2, firstResponse: 0.2, settle: 0.05)
        let provider = SudoElevationProvider(
            target: SudoTarget(nodeID: nodeID, host: "h", usesSudo: true),
            secretStore: makeStore(password),
            timeouts: timeouts
        ) { _, line in
            SudoSFTPTransport(process: process, passwordLine: line, timeouts: timeouts)
        }
        let producedTransport = await provider.elevatedTransport(for: "/x")
        let transport = try XCTUnwrap(producedTransport)
        do {
            try await transport.open()
            XCTFail("expected the setup to time out")
        } catch SFTPError.elevationFailed(let failure) {
            XCTAssertEqual(failure.kind, .timedOut)
        }
    }

    func testFirstResponseTimeoutWhenTheServerStaysSilent() async throws {
        let process = FakeElevatedProcess()
        process.hangsOnRead = true
        let timeouts = ElevationTimeouts(setup: 1, firstResponse: 0.2, settle: 0.05)
        let provider = SudoElevationProvider(
            target: SudoTarget(nodeID: nodeID, host: "h", usesSudo: true),
            secretStore: makeStore(password),
            timeouts: timeouts
        ) { _, line in
            SudoSFTPTransport(process: process, passwordLine: line, timeouts: timeouts)
        }
        let producedTransport = await provider.elevatedTransport(for: "/x")
        let transport = try XCTUnwrap(producedTransport)
        try await transport.open()
        do {
            _ = try transport.read(maxLength: 1024)
            XCTFail("expected a first-response timeout")
        } catch SFTPError.elevationFailed(let failure) {
            XCTAssertEqual(failure.kind, .timedOut)
        }
        transport.close()
    }

    func testCleanEOFWithoutStderrIsNotReportedAsATimeout() async throws {
        let process = FakeElevatedProcess()   // no stdout, no stderr
        let timeouts = ElevationTimeouts(setup: 1, firstResponse: 0.5, settle: 0.05)
        let provider = SudoElevationProvider(
            target: SudoTarget(nodeID: nodeID, host: "h", usesSudo: true),
            secretStore: makeStore(password),
            timeouts: timeouts
        ) { _, line in
            SudoSFTPTransport(process: process, passwordLine: line, timeouts: timeouts)
        }
        let producedTransport = await provider.elevatedTransport(for: "/x")
        let transport = try XCTUnwrap(producedTransport)
        try await transport.open()
        XCTAssertNil(try transport.read(maxLength: 1024), "EOF must read as EOF")
        transport.close()
    }
}
