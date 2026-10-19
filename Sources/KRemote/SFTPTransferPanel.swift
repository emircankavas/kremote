import SwiftUI
import KRemoteCore
import AppKit

/// The collapsible transfer queue at the bottom of the SFTP window.
///
/// A plain disclosure over the session's `TransferQueue`: it draws rows, and every
/// action is a call back into the session or the queue. No I/O happens here, so
/// the panel is testable and the window keeps one owner for transfers.
struct SFTPTransferPanel: View {
    let session: SFTPSession

    @State private var isHovering = false

    private var queue: TransferQueue { session.transfers }

    var body: some View {
        VStack(spacing: 0) {
            header
            if queue.isExpanded, queue.hasWork {
                Divider()
                list
            }
        }
        .background(.bar)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                queue.isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: queue.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Image(systemName: "arrow.up.arrow.down.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("Transfers")
                        .font(.callout.weight(.medium))
                    if let summary = queue.summary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Transfers")
            .accessibilityValue(queue.summary ?? "none")
            .accessibilityHint(queue.isExpanded ? "Collapse the transfer queue" : "Expand the transfer queue")

            if queue.runningCount > 0 {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("\(queue.runningCount) transfers running")
            }

            Spacer()

            if queue.failedCount > 0 {
                Button("Retry All") { retryAll() }
                    .controlSize(.small)
                    .accessibilityLabel("Retry all failed transfers")
            }
            if queue.runningCount > 0 || queue.queuedCount > 0 {
                Button("Cancel All") { queue.cancelAll() }
                    .controlSize(.small)
                    .accessibilityLabel("Cancel all transfers")
            }
            if queue.items.contains(where: { $0.isFinished || $0.state == .cancelled }) {
                Button("Clear") { queue.clearFinished() }
                    .controlSize(.small)
                    .accessibilityLabel("Clear finished transfers")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { queue.isExpanded.toggle() }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(queue.items) { item in
                    row(item)
                    Divider().opacity(0.3)
                }
            }
        }
        .frame(maxHeight: 168)
    }

    private func row(_ item: TransferItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.icon)
                .foregroundStyle(iconColor(item))
                .frame(width: 16)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail(item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if item.isRunning {
                if let fraction = item.fraction {
                    ProgressView(value: fraction)
                        .frame(width: 90)
                        .accessibilityLabel("\(Int(fraction * 100)) percent")
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 90)
                        .accessibilityLabel("Transferring")
                }
                if let throughput = item.throughputText {
                    Text(throughput)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 130, alignment: .trailing)
                }
                Button {
                    queue.cancel(item.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel this transfer")
                .accessibilityLabel("Cancel \(item.name)")
            } else if item.isQueued {
                Text("Queued")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    queue.cancel(item.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove from the queue")
                .accessibilityLabel("Remove \(item.name) from the queue")
            } else if item.failureReason != nil {
                Button("Retry") { retry(item) }
                    .controlSize(.small)
                    .accessibilityLabel("Retry \(item.name)")
                if item.kind != .upload, let url = item.localURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .help("Reveal in Finder")
                    .accessibilityLabel("Reveal \(item.name) in Finder")
                    .disabled(!FileManager.default.fileExists(atPath: url.path))
                }
            } else if item.isFinished {
                if item.kind != .upload, let url = item.localURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .help("Reveal in Finder")
                    .accessibilityLabel("Reveal \(item.name) in Finder")
                }
                Button {
                    queue.remove(item.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Remove from the list")
                .accessibilityLabel("Remove \(item.name) from the list")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(item))
    }

    private func iconColor(_ item: TransferItem) -> Color {
        if item.failureReason != nil { return .red }
        if item.isFinished { return .green }
        return .secondary
    }

    private func detail(_ item: TransferItem) -> String {
        switch item.state {
        case .queued:
            return "Waiting · \(item.remotePath)"
        case .running:
            return item.progressText
        case .finished:
            return "Done · \(item.progressText)"
        case .failed(let reason):
            return reason
        case .cancelled:
            return "Cancelled"
        }
    }

    private func accessibilityText(_ item: TransferItem) -> String {
        let state: String
        switch item.state {
        case .queued: state = "Queued"
        case .running: state = "Transferring, \(item.progressText)"
        case .finished: state = "Finished, \(item.progressText)"
        case .failed(let reason): state = "Failed: \(reason)"
        case .cancelled: state = "Cancelled"
        }
        return "\(item.name), \(state)"
    }

    private func retry(_ item: TransferItem) {
        queue.retry(item.id)
        session.startTransfers()
    }

    private func retryAll() {
        for item in queue.items where item.failureReason != nil {
            queue.retry(item.id)
        }
        session.startTransfers()
    }
}
