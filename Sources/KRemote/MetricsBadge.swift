import SwiftUI
import KRemoteCore

/// Live CPU and memory for a session, shown in its status bar.
///
/// Two ways in, because the two protocols are different:
///
/// - **SSH** samples over a separate command channel (`MetricsSampler`), leaving the
///   interactive terminal alone.
/// - **RDP** carries a desktop, not counters, so a Windows host is asked over WinRM.
///   When WinRM is not enabled — a normal setup, since RDP does not need it — the
///   badge shows nothing at all. An error there would read as a fault in KRemote
///   for a machine that is simply not configured for it.
///
/// Polling stops when the pane goes away, so a closed tab leaves no traffic behind.
struct MetricsBadge: View {
    enum Source {
        /// A Unix host: sample over ssh.
        case shell(host: String, port: Int, username: String, identityFile: String, password: String)
        /// A Windows host: sample over WinRM.
        case winrm(host: String, username: String, password: String)
    }

    let source: Source
    /// Shown only when the connection is live: polling a dead server is noise.
    let isActive: Bool

    @State private var metrics: SystemMetrics?
    @State private var failure: String?
    @State private var sampler: MetricsSampler?
    @State private var polling: Task<Void, Never>?
    @State private var showDetail = false

    var body: some View {
        Group {
            if let metrics {
                Button {
                    showDetail.toggle()
                } label: {
                    HStack(spacing: 8) {
                        metric("cpu", value: metrics.cpuText)
                        metric("memorychip", value: metrics.memoryText)
                    }
                }
                .buttonStyle(.plain)
                .help(detailTooltip(metrics))
                .popover(isPresented: $showDetail, arrowEdge: .bottom) {
                    detailPopover(metrics)
                }
            } else if case .shell = source {
                // A placeholder while the first sample is in flight, and the reason
                // if it never arrives. An invisible icon was the old behaviour and it
                // read as "the feature is missing" rather than "the sample failed" —
                // so this is a button that always occupies space and can be clicked
                // for the reason.
                Button {
                    showDetail.toggle()
                } label: {
                    HStack(spacing: 8) {
                        metric("cpu", value: "–")
                        metric("memorychip", value: "–")
                    }
                }
                .buttonStyle(.plain)
                .help(failure ?? "Reading the server's load…")
                .popover(isPresented: $showDetail, arrowEdge: .bottom) {
                    failurePopover
                }
            }
            // A WinRM failure draws nothing: "WinRM is off" is not a KRemote problem.
        }
        // Without this the badge is the first thing a narrow pane squeezes, and the
        // numbers truncate to "9…" — present in the layout, unreadable to a person.
        .fixedSize()
        .layoutPriority(2)
        .onAppear { sync() }
        .onDisappear { stop() }
        .onChange(of: isActive) { _, _ in sync() }
    }

    private func metric(_ symbol: String, value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func detailTooltip(_ metrics: SystemMetrics) -> String {
        var lines = ["CPU \(metrics.cpuText)", "Memory \(metrics.memoryText)"]
        if let detail = metrics.memoryDetail { lines.append(detail) }
        if let load = metrics.loadDetail { lines.append("Load \(load)") }
        if let uptime = metrics.uptimeDetail { lines.append("Up \(uptime)") }
        return lines.joined(separator: "\n")
    }

    private func detailPopover(_ metrics: SystemMetrics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            row("CPU", metrics.cpuText)
            if let detail = metrics.memoryDetail {
                row("Memory", "\(metrics.memoryText) · \(detail)")
            } else {
                row("Memory", metrics.memoryText)
            }
            if let load = metrics.loadDetail { row("Load", load) }
            if let swap = metrics.swapDetail { row("Swap", swap) }
            if let uptime = metrics.uptimeDetail { row("Uptime", uptime) }
            Text(hostLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
    }

    private var failurePopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Server load unavailable")
                .font(.caption.weight(.semibold))
            Text(failure ?? "Waiting for the first reading…")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 260, alignment: .leading)
            Text(hostLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
    }

    private var hostLabel: String {
        switch source {
        case .shell(let host, _, _, _, _): return host
        case .winrm(let host, _, _): return "\(host) · WinRM"
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(.caption.monospacedDigit())
        }
    }

    // MARK: - Lifecycle

    private func sync() {
        if isActive { startIfNeeded() } else { stop() }
    }

    private func startIfNeeded() {
        guard sampler == nil, polling == nil else { return }
        switch source {
        case .shell(let host, let port, let username, let identityFile, let password):
            guard !host.isEmpty else { return }
            // One shared authenticated connection for every sample, so a
            // password-only server is not asked for a password every five seconds.
            let controlPath = RemoteShell.controlPath(
                for: host, port: port, username: username,
                in: MetricsPaths.controlDirectory()
            )
            let shell = RemoteShell(
                host: host, port: port, username: username,
                identityFile: identityFile, password: password,
                controlPath: controlPath
            )
            // No control path: a plain connection, used if the shared one cannot be
            // established. Costs one authentication per sample, and is the only way
            // the figures appear at all on a server that refuses the master.
            let plain = RemoteShell(
                host: host, port: port, username: username,
                identityFile: identityFile, password: password
            )
            let sampler = MetricsSampler(shell: shell, fallback: plain)
            self.sampler = sampler
            Task {
                await sampler.start { state in
                    Task { @MainActor in apply(state) }
                }
            }

        case .winrm(let host, let username, let password):
            guard !host.isEmpty, !username.isEmpty else { return }
            polling = Task {
                while !Task.isCancelled {
                    do {
                        let sample = try await WinRMMetricsProbe.sample(
                            host: host, username: username, password: password)
                        await MainActor.run {
                            metrics = sample
                            failure = nil
                        }
                    } catch {
                        // WinRM off, credentials wrong, firewall closed — all of
                        // them mean "no figures", never an error in the bar.
                        await MainActor.run {
                            metrics = nil
                            failure = error.localizedDescription
                        }
                        return
                    }
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        }
    }

    private func stop() {
        if let sampler {
            self.sampler = nil
            Task { await sampler.stop() }
        }
        polling?.cancel()
        polling = nil
    }

    @MainActor
    private func apply(_ state: MetricsSampler.State) {
        switch state {
        case .ready(let value):
            metrics = value
            failure = nil
        case .failed(let reason):
            failure = reason
            metrics = nil
            MetricsLog.record("SSH sample failed for \(hostLabel): \(reason)")
        case .idle, .sampling:
            break
        }
    }
}
