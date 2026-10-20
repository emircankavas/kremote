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
            } else {
                // No reading yet, or none possible. This is drawn for both sources:
                // showing nothing at all left the badge indistinguishable from a
                // feature that was never wired up, and gave no way to reach the
                // reason. It still shows no number — just placeholders — so a host
                // that cannot answer is never made to look measured.
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
        VStack(alignment: .leading, spacing: 8) {
            Text(failure == nil ? "Reading the server's load…" : "Server load unavailable")
                .font(.caption.weight(.semibold))

            if let failure {
                Text(failure)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 280, alignment: .leading)
                    .textSelection(.enabled)
            }

            // A WinRM host has a specific, checkable cause, so name the fix rather
            // than leaving the user with a TCP error and no next step. RDP does not
            // need WinRM, which is why this is worded as "to show figures" and not
            // as a fault.
            if case .winrm = source, failure != nil {
                Divider()
                Text("To show load figures, this Windows host must answer WinRM:")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // One short line per part, so nothing wraps: a command copied out of
                // a popover with a line break in the middle is a broken command.
                VStack(alignment: .leading, spacing: 3) {
                    Text("Enable-PSRemoting -Force")
                    Text("-SkipNetworkProfileCheck")
                    Text("Set-NetFirewallRule")
                    Text("-DisplayGroup \"Windows Remote")
                    Text("Management\" -Enabled True -Profile Any")
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

                Text("Ports tried: 5985 and 5986.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("RDP works without WinRM; the figures stay blank.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            Text(hostLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: 300, alignment: .leading)
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
            guard !host.isEmpty else { return }
            guard !username.isEmpty else {
                // Nothing to authenticate with, so say that instead of polling a
                // server that would reject an empty account.
                failure = "This connection has no username, so WinRM has nothing to authenticate."
                return
            }
            polling = Task {
                while !Task.isCancelled {
                    var succeeded = false
                    do {
                        // 5985 first, then 5986: RDP does not say which listener
                        // the host has, and a hardened machine may only allow the
                        // encrypted one.
                        let sample = try await WinRMMetricsProbe.sampleAutomatically(
                            host: host, username: username, password: password)
                        await MainActor.run {
                            metrics = sample
                            failure = nil
                        }
                        succeeded = true
                    } catch {
                        // WinRM off, credentials wrong, firewall closed. The numbers
                        // stay blank and the reason is kept, but polling continues on a
                        // slower cadence: a user who enables WinRM while the session is
                        // open should see the badge come alive, not have to reopen the
                        // tab.
                        await MainActor.run {
                            metrics = nil
                            failure = error.localizedDescription
                        }
                    }
                    let delay: UInt64 = succeeded ? 5_000_000_000 : 30_000_000_000
                    try? await Task.sleep(nanoseconds: delay)
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
