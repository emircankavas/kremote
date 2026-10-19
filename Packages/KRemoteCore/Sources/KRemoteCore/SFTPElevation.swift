import Foundation

// MARK: - Failures

/// Why an elevation attempt did not produce a usable channel.
///
/// The cases exist because the UI has to say something different for each: a
/// wrong password is the user's to fix, a missing sudoers entry is the
/// administrator's, and a server without an `sftp-server` binary is neither.
public enum ElevationFailureKind: String, Sendable, Equatable, CaseIterable {
    /// sudo read the password line and refused it (or was given nothing).
    case passwordRejected
    /// The account may not run sudo at all (no sudoers entry / not allowed).
    case notPermitted
    /// No `sftp-server` binary on the server (checked the usual paths, PATH and
    /// `sshd_config`).
    case sftpServerMissing
    /// sudo insists on a terminal (`requiretty` / `Defaults use_pty` setups that
    /// reject a password on stdin).
    case terminalRequired
    /// The elevated connection did not answer within the timeout.
    case timedOut
    /// The ssh process died before the subsystem started.
    case connectionFailed
    case unknown
}

extension ElevationFailureKind {
    /// Wording for the single alert the UI shows. Kept in the core so every
    /// client words the same failure the same way; the raw stderr is shown
    /// alongside it.
    public var userFacingMessage: String {
        switch self {
        case .passwordRejected:
            return "sudo rejected the stored password. Fix the password on this connection and try again."
        case .notPermitted:
            return "This account is not allowed to use sudo on the server."
        case .sftpServerMissing:
            return "No sftp-server program was found on the server, so elevation is not possible."
        case .terminalRequired:
            return "sudo on this server requires a terminal, so it cannot read the password over this channel."
        case .timedOut:
            return "The elevated connection timed out before the server answered."
        case .connectionFailed:
            return "The elevated connection could not be started."
        case .unknown:
            return "Elevating with sudo failed."
        }
    }

    /// Best-effort classification of what sudo/ssh wrote to stderr.
    ///
    /// The text is matched, never parsed into a result the caller depends on for
    /// correctness: an unrecognised message degrades to `.unknown` and the raw
    /// text still reaches the user, so a sudo whose wording changes only loses
    /// the tailored hint.
    public static func classify(stderr: String) -> ElevationFailureKind {
        let text = stderr.lowercased()
        guard !text.isEmpty else { return .unknown }

        if text.contains("not in the sudoers file")
            || text.contains("not allowed to execute")
            || text.contains("is not allowed")
            || text.contains("may not run sudo")
            || text.contains("no valid sudoers sources") {
            return .notPermitted
        }
        if text.contains("a terminal is required")
            || text.contains("no tty present")
            || text.contains("must have a tty")
            || text.contains("requiretty") {
            return .terminalRequired
        }
        if text.contains("no sftp-server")
            || text.contains("sftp-server: no such file")
            || text.contains("sftp-server: not found")
            || text.contains("sftp-server: command not found") {
            return .sftpServerMissing
        }
        if text.contains("sorry, try again")
            || text.contains("incorrect password")
            || text.contains("authentication failed")
            || text.contains("try again")
            || text.contains("a password is required")
            || text.contains("no password was provided") {
            return .passwordRejected
        }
        if text.contains("timed out") || text.contains("timeout") {
            return .timedOut
        }
        if text.contains("connection refused")
            || text.contains("connection reset")
            || text.contains("permission denied (publickey")
            || text.contains("could not resolve hostname")
            || text.contains("connection closed") {
            return .connectionFailed
        }
        return .unknown
    }
}

/// One failed elevation: the classification plus the server's own words.
///
/// `stderr` is verbatim output from ssh/sudo and never contains the password —
/// the password only ever travels as a single line on the child's stdin and ssh
/// does not echo stdin.
public struct ElevationFailure: Sendable, Equatable {
    public let kind: ElevationFailureKind
    public let stderr: String

    public init(kind: ElevationFailureKind, stderr: String) {
        self.kind = kind
        self.stderr = stderr
    }

    /// Builds a failure from raw stderr, classifying it.
    public init(stderr: String) {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(kind: ElevationFailureKind.classify(stderr: trimmed), stderr: trimmed)
    }
}

// MARK: - Command

/// The remote command that starts an sftp subsystem as root.
///
/// Path detection happens on the **server**, inside the one ssh connection the
/// elevation already needs. A separate probe connection would show up as a
/// second auth in the server log for every operation, and a hard-coded path is
/// wrong on at least one platform in daily use (macOS ships
/// `/usr/libexec/sftp-server`, Debian/Ubuntu `/usr/lib/openssh/sftp-server`).
public enum ElevationCommand {
    /// Candidate absolute paths, tried in order before falling back to PATH and
    /// then to `sshd_config`'s `Subsystem sftp` line.
    public static let candidatePaths = [
        "/usr/libexec/sftp-server",
        "/usr/lib/openssh/sftp-server",
    ]

    /// The command string handed to `ssh` as a single argument.
    ///
    /// `sudo -S -p ''` reads the password from stdin with no prompt text (so
    /// nothing prompt-like can ever land in the protocol stream), and `exec`
    /// keeps the same stdin/stdout for the subsystem. Every failure path writes
    /// one explanatory line to stderr and exits non-zero, so the caller has
    /// something to show instead of a silent hang.
    public static var remoteCommand: String {
        let candidates = candidatePaths.map { "\"\($0)\"" }.joined(separator: " ")
        return [
            "p=''",
            "for c in \(candidates); do if [ -x \"$c\" ]; then p=\"$c\"; break; fi; done",
            "if [ -z \"$p\" ]; then p=$(command -v sftp-server 2>/dev/null); fi",
            "if [ -z \"$p\" ]; then p=$(awk '/^[ \\t]*Subsystem[ \\t]+sftp[ \\t]/{print $3; exit}' /etc/ssh/sshd_config 2>/dev/null); fi",
            "if [ -z \"$p\" ] || [ \"$p\" = internal-sftp ]; then "
                + "echo 'sftp-server: no sftp-server binary found (checked /usr/libexec, /usr/lib/openssh, PATH, sshd_config)' >&2; "
                + "exit 127; fi",
            "exec sudo -S -p '' \"$p\"",
        ].joined(separator: "; ")
    }
}

// MARK: - Timeouts

/// How long the elevated setup and its first answer may take.
///
/// A server that silently swallows stdin (a `sudo` waiting for a password that
/// never arrives, a firewall dropping the channel) must fail with an error
/// rather than leave a window spinning forever.
public struct ElevationTimeouts: Sendable, Equatable {
    /// Covers spawning ssh, writing the password line and sudo's own answer.
    public var setup: TimeInterval
    /// Covers the SFTP VERSION exchange after the password was accepted.
    public var firstResponse: TimeInterval
    /// How long to watch stderr after the password line before handing over to
    /// the protocol. sudo answers immediately either way; the window only needs
    /// to be long enough to catch "Sorry, try again." before INIT is written.
    public var settle: TimeInterval

    public init(setup: TimeInterval = 15, firstResponse: TimeInterval = 15, settle: TimeInterval = 0.4) {
        self.setup = setup
        self.firstResponse = firstResponse
        self.settle = settle
    }

    public static let `default` = ElevationTimeouts()
}

/// Races `operation` against a deadline, returning whichever settles first.
///
/// Deliberately **not** a task group: a group waits for its cancelled children at
/// scope exit, and `Process.open()` cannot be cancelled — a hung connection would
/// keep the caller blocked, which is the exact failure this guards against. The
/// operation therefore runs detached, the caller resumes on the first result, and
/// on timeout the caller closes the transport so the orphaned attempt ends.
enum ElevationRace {
    enum Outcome<T: Sendable>: Sendable {
        case value(T)
        case timedOut
    }

    /// Resumes the continuation exactly once; late results are dropped.
    private final class Box<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Outcome<T>, Error>?
        private var settled = false

        init(_ continuation: CheckedContinuation<Outcome<T>, Error>) {
            self.continuation = continuation
        }

        func settle(_ result: Result<Outcome<T>, Error>) {
            let pending: CheckedContinuation<Outcome<T>, Error>? = lock.withLock {
                guard !settled else { return nil }
                settled = true
                let current = continuation
                continuation = nil
                return current
            }
            pending?.resume(with: result)
        }
    }

    static func run<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> Outcome<T> {
        try await withCheckedThrowingContinuation { continuation in
            let box = Box<T>(continuation)
            Task.detached(priority: .userInitiated) {
                do {
                    box.settle(.success(.value(try await operation())))
                } catch {
                    box.settle(.failure(error))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + max(0, seconds)) {
                box.settle(.success(.timedOut))
            }
        }
    }
}

// MARK: - Process surface

/// The pipe surface an elevated transport needs.
///
/// `ProcessSFTPTransport` is the real implementation; tests script it to stand
/// in for ssh + sudo, which is what makes the refusal paths testable without a
/// server.
public protocol ElevatedProcess: AnyObject, Sendable {
    func open() async throws
    func write(_ data: Data) throws
    func read(maxLength: Int) throws -> Data?
    func stderrText() -> String
    func close()
    var isAlive: Bool { get }
}

extension ProcessSFTPTransport: ElevatedProcess {}

// MARK: - Elevated transport

/// An SFTP transport reached through `ssh -T <host> "sudo -S … sftp-server"`.
///
/// The extra behaviour over the plain transport: write the password line before
/// any protocol byte, turn sudo's complaint into one typed error, and bound both
/// the setup and the wait for the first answer.
///
/// Reads are pumped on their own thread so `read(maxLength:)` can honour a
/// deadline — `SFTPTransport.read` is blocking by contract, and a server that
/// never answers is precisely what this guards against.
public final class SudoSFTPTransport: SFTPTransport, @unchecked Sendable {
    private let process: ElevatedProcess
    /// `password + "\n"` — the one line sudo reads. Never logged, never stored.
    private let passwordLine: Data
    private let timeouts: ElevationTimeouts

    private let condition = NSCondition()
    private var buffer = Data()
    private var terminalError: Error?
    private var reachedEOF = false
    private var pumpStarted = false
    private var closed = false

    public init(
        process: ElevatedProcess,
        passwordLine: Data,
        timeouts: ElevationTimeouts = .default
    ) {
        self.process = process
        self.passwordLine = passwordLine
        self.timeouts = timeouts
    }

    /// Diagnostics: the ssh argv. The password is never an argument.
    public var commandLine: [String] {
        (process as? ProcessSFTPTransport)?.commandLine ?? ["<scripted elevated process>"]
    }

    /// True once the password line was written and sudo stayed quiet long enough
    /// to be considered happy.
    public private(set) var didAuthenticate = false

    // MARK: Lifecycle

    public func open() async throws {
        let outcome: ElevationRace.Outcome<Void>
        do {
            outcome = try await ElevationRace.run(seconds: timeouts.setup) { [self] in
                try await setUp()
            }
        } catch let error as SFTPError {
            throw error
        } catch {
            throw SFTPError.elevationFailed(ElevationFailure(stderr: String(describing: error)))
        }
        if case .timedOut = outcome {
            close()
            throw SFTPError.elevationFailed(
                ElevationFailure(
                    kind: .timedOut,
                    stderr: "timed out after \(Int(timeouts.setup))s starting the elevated connection"
                )
            )
        }
        didAuthenticate = true
        startPump()
    }

    private func setUp() async throws {
        do {
            try await process.open()
        } catch {
            let reason = process.stderrText().trimmingCharacters(in: .whitespacesAndNewlines)
            close()
            throw SFTPError.elevationFailed(
                ElevationFailure(stderr: reason.isEmpty ? String(describing: error) : reason)
            )
        }

        // The password goes in first and alone, as one line. sudo consumes
        // exactly that line and leaves the rest of stdin to the subsystem.
        do {
            try process.write(passwordLine)
        } catch {
            let reason = process.stderrText().trimmingCharacters(in: .whitespacesAndNewlines)
            close()
            throw SFTPError.elevationFailed(ElevationFailure(kind: .connectionFailed, stderr: reason))
        }

        // Watch briefly for sudo complaining. A successful sudo is silent, so
        // anything on stderr in this window is a refusal; a dead child is one too.
        let deadline = Date().addingTimeInterval(timeouts.settle)
        while Date() < deadline {
            let text = process.stderrText().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                close()
                throw SFTPError.elevationFailed(ElevationFailure(stderr: text))
            }
            if !process.isAlive {
                close()
                throw SFTPError.elevationFailed(
                    ElevationFailure(
                        kind: .connectionFailed,
                        stderr: "the elevated ssh process exited during setup"
                    )
                )
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    public func close() {
        condition.withLock {
            closed = true
            condition.broadcast()
        }
        process.close()
    }

    public var isAlive: Bool { !condition.withLock { closed } && process.isAlive }

    public func stderrText() -> String { process.stderrText() }

    // MARK: IO

    public func write(_ data: Data) throws {
        let (failure, isClosed) = condition.withLock { (terminalError, closed) }
        if let failure { throw failure }
        guard !isClosed else { throw SFTPError.connectionClosed(process.stderrText()) }
        try process.write(data)
    }

    /// Returns buffered bytes, or waits until a byte arrives, EOF, an error, or
    /// the first-response deadline — whichever comes first.
    public func read(maxLength: Int) throws -> Data? {
        let deadline = Date().addingTimeInterval(timeouts.firstResponse)
        var sawAnyByte = false
        return try condition.withLock { () -> Data? in
            while true {
                if !buffer.isEmpty {
                    let chunk = buffer.prefix(maxLength)
                    buffer.removeFirst(chunk.count)
                    sawAnyByte = true
                    return Data(chunk)
                }
                if let terminalError { throw terminalError }
                if reachedEOF || closed { return nil }

                // Before the subsystem has said anything, a complaint on stderr
                // is sudo refusing us: fail now with the classification instead
                // of sitting out the whole response deadline.
                if !sawAnyByte {
                    let text = process.stderrText().trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        closed = true
                        condition.broadcast()
                        throw SFTPError.elevationFailed(ElevationFailure(stderr: text))
                    }
                }

                if Date() >= deadline {
                    closed = true
                    condition.broadcast()
                    // Classify whatever sudo did say, so a refusal is not dressed
                    // up as a timeout.
                    let text = process.stderrText().trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        throw SFTPError.elevationFailed(ElevationFailure(stderr: text))
                    }
                    throw SFTPError.elevationFailed(
                        ElevationFailure(
                            kind: .timedOut,
                            stderr: "no answer from the elevated sftp-server within \(Int(timeouts.firstResponse))s"
                        )
                    )
                }
                // Short slices so a refusal or `close()` can interrupt promptly.
                condition.wait(until: Date().addingTimeInterval(0.05))
            }
        }
    }

    private func startPump() {
        let alreadyStarted = condition.withLock { () -> Bool in
            if pumpStarted { return true }
            pumpStarted = true
            return false
        }
        guard !alreadyStarted else { return }

        let thread = Thread { [weak self] in
            guard let self else { return }
            while self.condition.withLock({ !self.closed }) {
                do {
                    guard let chunk = try self.process.read(maxLength: 64 * 1024) else {
                        // EOF: prefer sudo's own words over a bare "connection
                        // closed" — that is the alert the user needs.
                        let text = self.process.stderrText()
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        self.finish(error: text.isEmpty
                            ? nil
                            : SFTPError.elevationFailed(ElevationFailure(stderr: text)))
                        return
                    }
                    self.condition.withLock {
                        self.buffer.append(chunk)
                        self.condition.broadcast()
                    }
                } catch {
                    self.finish(error: error)
                    return
                }
            }
        }
        thread.name = "kremote.sudo-sftp-reader"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    private func finish(error: Error?) {
        condition.withLock {
            if let error { terminalError = error }
            reachedEOF = true
            condition.broadcast()
        }
    }
}

// MARK: - Provider

/// What the provider needs to reach the node and find its password.
public struct SudoTarget: Sendable, Equatable {
    public var nodeID: UUID
    public var host: String
    public var port: Int
    public var username: String
    public var identityFile: String
    /// The node's "use sudo" flag. Elevation never happens without it.
    public var usesSudo: Bool

    public init(
        nodeID: UUID,
        host: String,
        port: Int = 22,
        username: String = "",
        identityFile: String = "",
        usesSudo: Bool
    ) {
        self.nodeID = nodeID
        self.host = host
        self.port = port
        self.username = username
        self.identityFile = identityFile
        self.usesSudo = usesSudo
    }
}

/// The real `ElevationProvider`: one extra ssh connection per refused operation,
/// running the sftp subsystem under sudo with the node's stored password.
///
/// Deliberately **not** a mode and not cached: the base channel keeps doing
/// everything the login user may do, and only the operation that was refused
/// goes through here. Nothing is retried from inside the provider — one attempt
/// per call, and the client does not ask twice.
public final class SudoElevationProvider: ElevationProvider, @unchecked Sendable {
    /// Builds the transport for a remote command. Injected so the whole path can
    /// be tested with a scripted transport; the default spawns `ssh`.
    public typealias TransportFactory = @Sendable (String, Data) -> SFTPTransport

    private let target: SudoTarget
    private let secretStore: SecretStore
    private let timeouts: ElevationTimeouts
    private let factory: TransportFactory

    public init(
        target: SudoTarget,
        secretStore: SecretStore,
        timeouts: ElevationTimeouts = .default,
        transportFactory: TransportFactory? = nil
    ) {
        self.target = target
        self.secretStore = secretStore
        self.timeouts = timeouts
        if let transportFactory {
            self.factory = transportFactory
        } else {
            let target = target
            let timeouts = timeouts
            self.factory = { remoteCommand, passwordLine in
                // ssh itself authenticates with the same stored password (there is
                // no terminal to prompt on), and the password is *also* written to
                // stdin for sudo once the channel is up.
                let loginPassword = String(decoding: passwordLine.dropLast(), as: UTF8.self)
                return SudoSFTPTransport(
                    process: ProcessSFTPTransport(
                        host: target.host,
                        port: target.port,
                        username: target.username,
                        identityFile: target.identityFile,
                        password: loginPassword,
                        remoteCommand: remoteCommand
                    ),
                    passwordLine: passwordLine,
                    timeouts: timeouts
                )
            }
        }
    }

    /// True when the stored password can be sent as one stdin line.
    ///
    /// A password with a newline in it would be split, and the tail would land in
    /// the protocol stream as garbage; an empty one cannot succeed. Both are
    /// treated as "no usable password", which means no attempt at all.
    public static func isUsable(password: String) -> Bool {
        guard !password.isEmpty else { return false }
        guard !password.contains("\n"), !password.contains("\r") else { return false }
        return !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// `nil` when the node has no sudo flag or no usable password — the caller
    /// then rethrows the original permission error, unchanged.
    public func elevatedTransport(for path: String) async -> SFTPTransport? {
        guard target.usesSudo else { return nil }
        guard let stored = (try? secretStore.secret(for: target.nodeID)) ?? nil,
              Self.isUsable(password: stored) else {
            return nil
        }
        // Only the line terminator is added; the secret itself never leaves this
        // call as anything but the single line handed to the transport.
        let line = Data((stored + "\n").utf8)
        return factory(ElevationCommand.remoteCommand, line)
    }

    /// Answered without exposing the secret: the flag and whether a usable
    /// password is stored.
    public var elevationAvailability: ElevationAvailability {
        guard target.usesSudo else { return .disabled }
        guard let stored = (try? secretStore.secret(for: target.nodeID)) ?? nil,
              Self.isUsable(password: stored) else {
            return .noPassword
        }
        return .available
    }
}

extension SudoElevationProvider: ElevationCapabilityReporting {}
