import Foundation

/// Samples a server's CPU and memory every few seconds for the status bar.
///
/// One `ssh -T` per sample would re-authenticate constantly: on a password-only
/// server that is a fresh askpass round trip every five seconds. Instead every
/// sample rides one **control master** (`ControlMaster=auto` with a private
/// socket), so authentication happens once and a probe costs a round trip.
///
/// Deliberately not an `ObservableObject`: the core has no UI framework in it, and
/// the SwiftUI side wraps this with a small adapter. That also makes the sampler
/// testable against a scripted shell.
public actor MetricsSampler {
    public enum State: Equatable, Sendable {
        case idle
        case sampling
        case ready(SystemMetrics)
        case failed(String)
    }

    /// Five seconds: fast enough that a spike is visible, slow enough that the
    /// probe's own 0.35 s sleep (and macOS's 1 s `top` sample) is a fraction of it.
    public let interval: TimeInterval

    private let shell: RemoteShell
    private var running = false
    private var consecutiveFailures = 0
    private var onChange: (@Sendable (State) -> Void)?

    public private(set) var state: State = .idle

    public init(shell: RemoteShell, interval: TimeInterval = 5) {
        self.shell = shell
        self.interval = interval
    }

    /// Starts polling. Idempotent: a second call does not open a second loop.
    public func start(onChange: @escaping @Sendable (State) -> Void) {
        guard !running else { return }
        running = true
        self.onChange = onChange
        publish(.sampling)
        Task { [weak self] in
            await self?.loop()
        }
    }

    public func stop() {
        running = false
        publish(.idle)
        shell.closeControlMaster()
    }

    /// One sample now: the loop's body, reachable for a manual refresh.
    @discardableResult
    public func sampleOnce() async -> State {
        do {
            let metrics = try await SystemMetricsProbe.sample(using: shell)
            consecutiveFailures = 0
            publish(.ready(metrics))
        } catch {
            consecutiveFailures += 1
            // One dropped sample is noise: a loaded server hiccups, and the probe's
            // own `sleep 0.35` can be delayed. Replacing live numbers with an error
            // on the first miss makes the bar flicker, so it takes two — except at
            // startup, where there is nothing to keep showing.
            if consecutiveFailures >= 2 || state == .sampling {
                publish(.failed(Self.message(for: error)))
            }
        }
        return state
    }

    private func loop() async {
        while running {
            await sampleOnce()
            if !running { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            } catch {
                return
            }
        }
    }

    private func publish(_ new: State) {
        state = new
        onChange?(new)
    }

    static func message(for error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription { return localized }
        return error.localizedDescription
    }
}

/// Where control-master sockets live.
public enum MetricsPaths {
    /// A per-user directory under the cache folder.
    ///
    /// Not `NSTemporaryDirectory()`: that is wiped without warning, and a master
    /// whose socket disappears cannot be reused or cleanly closed.
    public static func controlDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("KRemote/metrics", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
