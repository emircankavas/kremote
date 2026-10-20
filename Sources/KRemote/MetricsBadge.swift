import SwiftUI
import KRemoteCore

/// Live CPU and memory for a session, shown in its status bar.
///
/// Bridges `MetricsSampler` (a core actor, no UI framework) to SwiftUI: the view
/// asks for a sample every five seconds while it is on screen, and stops when it
/// goes away so a closed tab leaves no ssh process behind.
///
/// SSH samples the box over a separate command channel; RDP samples it over ssh
/// to the same host, because RDP itself carries a desktop, not counters.
struct MetricsBadge: View {
    let host: String
    let port: Int
    let username: String
    let identityFile: String
    let password: String
    /// Shown only when the connection is live: polling a dead server is noise.
    let isActive: Bool

    @State private var metrics: SystemMetrics?
    @State private var failure: String?
    @State private var sampler: MetricsSampler?
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
            } else if failure != nil {
                // A closed eye rather than a red error: the session itself is fine,
                // only the figures are missing, and the reason is one click away.
                Image(systemName: "chart.bar.xaxis")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help(failure ?? "")
            }
        }
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
            Text(host)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
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
        if isActive {
            startIfNeeded()
        } else {
            stop()
        }
    }

    private func startIfNeeded() {
        guard sampler == nil, !host.isEmpty else { return }
        // One shared authenticated connection for every sample, so a password-only
        // server is not asked for a password every five seconds.
        let controlPath = RemoteShell.controlPath(
            for: host,
            port: port,
            username: username,
            in: MetricsPaths.controlDirectory()
        )
        let shell = RemoteShell(
            host: host,
            port: port,
            username: username,
            identityFile: identityFile,
            password: password,
            controlPath: controlPath
        )
        let sampler = MetricsSampler(shell: shell)
        self.sampler = sampler
        Task {
            await sampler.start { state in
                Task { @MainActor in apply(state) }
            }
        }
    }

    private func stop() {
        guard let sampler else { return }
        self.sampler = nil
        Task { await sampler.stop() }
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
        case .idle, .sampling:
            break
        }
    }
}
