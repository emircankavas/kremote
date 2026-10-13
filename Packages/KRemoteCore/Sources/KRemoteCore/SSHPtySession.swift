import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Runs the system `ssh` (OpenSSH) under a pseudo-terminal and bridges its bytes
/// to a terminal view.
///
/// Why the system binary rather than an SSH library: OpenSSH already speaks every
/// method a corporate server may demand — publickeys, `ssh-agent`, GSSAPI/Kerberos
/// SSO, keyboard-interactive, `~/.ssh/config`, ProxyJump, ControlMaster. Pure-Swift
/// stacks (e.g. NIOSSH) implement only publickey/password and cannot reach those.
/// This is the same choice mRemoteNXT and Royal TSX make.
///
/// Threading: `forkpty` spawns the child. Output is drained on a dedicated
/// **serial** `readQueue` that only ever reads (it blocks in `read`); input,
/// resize and teardown go on a separate serial `ioQueue` that only ever writes or
/// issues ioctls. Keeping reads and writes on separate queues is essential — if
/// they shared one queue, the blocking read would starve every keystroke.
public final class SSHPtySession: @unchecked Sendable {

    public enum State: Equatable, Sendable {
        case idle
        case connecting
        case connected
        case disconnected(String?)
    }

    private let onOutput: @Sendable (Data) -> Void
    private let onStateChange: @Sendable (State) -> Void

    private let readQueue = DispatchQueue(label: "com.emircankavas.kremote.pty.read")
    private let ioQueue = DispatchQueue(label: "com.emircankavas.kremote.pty.io")

    // Guarded by `fdLock`: the fd is written on ioQueue/start and read on readQueue.
    private let fdLock = NSLock()
    private var _masterFD: Int32 = -1
    private var masterFD: Int32 {
        get { fdLock.withLock { _masterFD } }
        set { fdLock.withLock { _masterFD = newValue } }
    }

    private var childPID: pid_t = -1
    private var connectedReported = false
    private var passwordSent = false

    /// Optional password to type into the PTY when ssh prompts for one. Written to
    /// the terminal, never to argv (argv is visible in `ps`).
    private var password: String = ""

    public init(
        onOutput: @escaping @Sendable (Data) -> Void,
        onStateChange: @escaping @Sendable (State) -> Void
    ) {
        self.onOutput = onOutput
        self.onStateChange = onStateChange
    }

    // MARK: - Lifecycle

    public func start(
        command: SSHCommandBuilder,
        password: String,
        columns: Int,
        rows: Int
    ) {
        self.password = password
        onStateChange(.connecting)

        // Spawning (which can block briefly) goes on ioQueue; the read loop then
        // takes over readQueue for the session's lifetime.
        ioQueue.async { [self] in
            var winSize = winsize(
                ws_row: UInt16(max(2, rows)),
                ws_col: UInt16(max(2, columns)),
                ws_xpixel: 0,
                ws_ypixel: 0
            )

            var master: Int32 = -1
            guard let pid = Self.fork(
                andExec: Self.sshPath,
                args: command.arguments,
                windowSize: &winSize,
                master: &master
            ) else {
                onStateChange(.disconnected("Could not start ssh (forkpty failed)."))
                return
            }

            masterFD = master
            childPID = pid

            readQueue.async { [self] in
                readLoop()

                var status: Int32 = 0
                _ = waitpid(pid, &status, 0)
                let reason = Self.describeExit(status)
                cleanup()
                onStateChange(.disconnected(reason))
            }
        }
    }

    private func readLoop() {
        let bufferSize = 16 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        // Rolling tail to spot the password prompt across chunk boundaries.
        var tail = Data()

        while true {
            let fd = masterFD
            if fd < 0 { break }

            let count = read(fd, &buffer, bufferSize)
            if count > 0 {
                let data = Data(bytes: buffer, count: count)
                onOutput(data)

                if !connectedReported {
                    connectedReported = true
                    onStateChange(.connected)
                }
                if !password.isEmpty, !passwordSent {
                    tail.append(data)
                    if tail.count > 256 { tail = tail.suffix(256) }
                    if let text = String(data: tail, encoding: .utf8),
                       Self.looksLikePasswordPrompt(text) {
                        passwordSent = true
                        write(Data((password + "\n").utf8))
                    }
                }
            } else if count == 0 {
                break // EOF: child closed the PTY.
            } else {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    usleep(20_000)
                    continue
                }
                break
            }
        }
    }

    // MARK: - Input / resize

    public func send(_ data: Data) {
        ioQueue.async { [self] in write(data) }
    }

    private func write(_ data: Data) {
        let fd = masterFD
        guard fd >= 0 else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, base + offset, raw.count - offset)
                if n > 0 { offset += n }
                else if errno == EINTR { continue }
                else { break }
            }
        }
    }

    public func resize(columns: Int, rows: Int) {
        ioQueue.async { [self] in
            let fd = masterFD
            guard fd >= 0 else { return }
            var ws = winsize(
                ws_row: UInt16(max(2, rows)),
                ws_col: UInt16(max(2, columns)),
                ws_xpixel: 0,
                ws_ypixel: 0
            )
            _ = ioctl(fd, TIOCSWINSZ, &ws)
        }
    }

    public func disconnect() {
        ioQueue.async { [self] in
            let pid = childPID
            if pid > 0 {
                kill(pid, SIGHUP)
                kill(pid, SIGKILL)
            }
            cleanup()
            onStateChange(.disconnected(nil))
        }
    }

    private func cleanup() {
        let fd = masterFD
        if fd >= 0 {
            close(fd)
            masterFD = -1
        }
        childPID = -1
    }

    // MARK: - Helpers

    /// ssh prints e.g. `user@host's password:` (and `Password:` for some servers).
    static func looksLikePasswordPrompt(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("password:") || lower.contains("password for")
    }

    static var sshPath: String {
        for candidate in ["/usr/bin/ssh", "/usr/local/bin/ssh", "/opt/homebrew/bin/ssh"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return "/usr/bin/ssh"
    }

    private static func describeExit(_ status: Int32) -> String? {
        // (status & 0x7f) == 0 means a normal exit; the code is in bits 8..15.
        if (status & 0x7f) == 0 {
            return "ssh exited with status \((status >> 8) & 0xff)"
        }
        return nil
    }

    /// fork + exec on a new PTY (the forkpty(3) pattern).
    private static func fork(
        andExec executable: String,
        args: [String],
        windowSize: inout winsize,
        master: inout Int32
    ) -> pid_t? {
        let cArgs = args.map { strdup($0) } + [nil]
        defer { for case let pointer? in cArgs { free(pointer) } }
        guard let cExec = strdup(executable) else { return nil }
        defer { free(cExec) }

        var env: [String: String] = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        // Force a clean locale so the password prompt is ASCII and matchable.
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for case let pointer? in cEnv { free(pointer) } }

        var masterFD: Int32 = 0
        let pid = forkpty(&masterFD, nil, nil, &windowSize)
        if pid < 0 { return nil }
        if pid == 0 {
            execve(cExec, cArgs, cEnv)
            _exit(127)
        }
        master = masterFD
        return pid
    }
}
