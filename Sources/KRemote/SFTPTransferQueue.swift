import Foundation
import Observation
import KRemoteCore

/// One row in the window's transfer queue.
///
/// A value the view draws, not an actor: the session owns the list and updates it
/// on the main actor, so the queue panel has nothing to synchronise.
struct TransferItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case download
        case upload
        /// Remote→remote copy, implemented as download+upload (roadmap: `copy`).
        case internalCopy
    }

    enum State: Equatable {
        case queued
        case running
        case finished
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let kind: Kind
    /// What the row says: the file or folder name being moved.
    let name: String
    let remotePath: String
    let localURL: URL?
    var state: State = .queued
    var bytesDone: Int64 = 0
    var bytesTotal: Int64?
    /// Bytes per second, smoothed, only while running.
    var throughput: Double = 0
    /// When the transfer started, for the elapsed/remaining display.
    var startedAt: Date?

    var isQueued: Bool { state == .queued }
    var isRunning: Bool { state == .running }
    var isFinished: Bool { state == .finished }

    var failureReason: String? {
        if case .failed(let reason) = state { return reason }
        return nil
    }

    var fraction: Double? {
        guard let bytesTotal, bytesTotal > 0 else { return nil }
        return min(1, max(0, Double(bytesDone) / Double(bytesTotal)))
    }

    var progressText: String {
        let done = ByteFormatter.string(UInt64(max(0, bytesDone)))
        if let bytesTotal, bytesTotal > 0 {
            return "\(done) of \(ByteFormatter.string(UInt64(bytesTotal)))"
        }
        return done
    }

    /// `3.4 MB/s · 12 s left` — only the parts that are known.
    var throughputText: String? {
        guard throughput > 0 else { return nil }
        var parts = ["\(ByteFormatter.string(UInt64(throughput)))/s"]
        if let bytesTotal, bytesTotal > bytesDone, throughput > 0 {
            let seconds = Double(bytesTotal - bytesDone) / throughput
            if seconds.isFinite, seconds >= 1 {
                parts.append(seconds < 60
                    ? "\(Int(seconds.rounded())) s left"
                    : "\(Int((seconds / 60).rounded())) min left")
            }
        }
        return parts.joined(separator: " · ")
    }

    var icon: String {
        if isFinished {
            switch kind {
            case .download: return "arrow.down.circle.fill"
            case .upload: return "arrow.up.circle.fill"
            case .internalCopy: return "doc.on.doc.fill"
            }
        }
        switch kind {
        case .download: return "arrow.down.circle"
        case .upload: return "arrow.up.circle"
        case .internalCopy: return "doc.on.doc"
        }
    }
}

/// The transfer queue: enqueue, run with bounded parallelism, cancel, retry.
///
/// Deliberately not an actor: it lives on `SFTPSession` (main actor), mutates a
/// value array the view observes, and hands the actual I/O to `SFTPClient`'s
/// nonisolated `async` methods. Two rules from the card are enforced here rather
/// than in the view:
///
/// * at most `maxConcurrent` transfers run at once, the rest wait in order;
/// * one item failing never stops the others — its row carries the error and the
///   queue moves on.
@MainActor
@Observable
final class TransferQueue {
    /// Small and fixed: SFTP is a single serialised request channel per client, so
    /// more parallelism buys scheduling noise rather than throughput.
    static let maxConcurrent = 3

    private(set) var items: [TransferItem] = []
    /// Collapsed by default so the queue does not steal space until it has work.
    var isExpanded = false

    /// Cancellation flags, keyed by item id. `SFTPClient` polls them between
    /// chunks; a flag stays set so a cancelled item cannot be resumed by mistake.
    ///
    /// Guarded by a lock, not by the main actor: the transfer code polls this from
    /// a nonisolated synchronous closure (`isCancelled:`), and reaching a
    /// main-actor property from there is a Swift 6 concurrency error — and, worse,
    /// a data race if it were allowed.
    private let cancelFlags = CancellationFlags()

    var runningCount: Int { items.filter(\.isRunning).count }
    var queuedCount: Int { items.filter(\.isQueued).count }
    var failedCount: Int { items.filter { $0.failureReason != nil }.count }
    var hasWork: Bool { !items.isEmpty }

    /// What the sidebar/status area summarises.
    var summary: String? {
        guard hasWork else { return nil }
        var parts: [String] = []
        if runningCount > 0 { parts.append("\(runningCount) transferring") }
        if queuedCount > 0 { parts.append("\(queuedCount) queued") }
        if failedCount > 0 { parts.append("\(failedCount) failed") }
        if parts.isEmpty {
            let done = items.filter(\.isFinished).count
            parts.append(done == 1 ? "1 transfer finished" : "\(done) transfers finished")
        }
        return parts.joined(separator: ", ")
    }

    func clearFinished() {
        items.removeAll { $0.isFinished || $0.state == .cancelled }
        // A failed item stays until the user retries or dismisses it: losing the
        // reason silently is worse than a row that lingers.
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        cancelFlags.clear(id)
    }

    /// Cancels one item. A queued item never starts; a running one stops at the
    /// next chunk boundary and its partial file is removed by the transfer code.
    func cancel(_ id: UUID) {
        cancelFlags.set(id)
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if items[index].isQueued {
            items[index].state = .cancelled
        }
    }

    func cancelAll() {
        for item in items where item.isQueued || item.isRunning {
            cancel(item.id)
        }
    }

    /// Safe from any thread/actor: the transfer engine calls this between chunks
    /// from a nonisolated context.
    nonisolated func isCancelled(_ id: UUID) -> Bool {
        cancelFlags.contains(id)
    }

    // MARK: - Enqueue

    @discardableResult
    func enqueueDownload(name: String, remotePath: String, localURL: URL) -> UUID {
        let item = TransferItem(
            kind: .download, name: name, remotePath: remotePath, localURL: localURL
        )
        items.append(item)
        return item.id
    }

    @discardableResult
    func enqueueUpload(name: String, remotePath: String, localURL: URL) -> UUID {
        let item = TransferItem(
            kind: .upload, name: name, remotePath: remotePath, localURL: localURL
        )
        items.append(item)
        return item.id
    }

    @discardableResult
    func enqueueCopy(name: String, remotePath: String, localURL: URL) -> UUID {
        let item = TransferItem(
            kind: .internalCopy, name: name, remotePath: remotePath, localURL: localURL
        )
        items.append(item)
        return item.id
    }

    /// Puts a failed item back in the queue with its counters reset.
    func retry(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        cancelFlags.clear(id)
        items[index].state = .queued
        items[index].bytesDone = 0
        items[index].throughput = 0
        items[index].startedAt = nil
    }

    // MARK: - State transitions used by the runner

    func markRunning(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = .running
        items[index].startedAt = Date()
    }

    func updateProgress(_ id: UUID, progress: TransferProgress) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let previousBytes = items[index].bytesDone
        items[index].bytesDone = progress.bytesDone
        if let total = progress.bytesTotal { items[index].bytesTotal = total }
        // Instantaneous rate would jump on every 32 KiB chunk; a moving average
        // over the transfer's own elapsed time is what a progress panel wants.
        if let started = items[index].startedAt {
            let elapsed = Date().timeIntervalSince(started)
            if elapsed > 0.25 {
                items[index].throughput = Double(progress.bytesDone) / elapsed
            }
        }
        _ = previousBytes
    }

    func markFinished(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = .finished
        items[index].throughput = 0
        if let total = items[index].bytesTotal { items[index].bytesDone = total }
    }

    func markFailed(_ id: UUID, reason: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = .failed(reason)
        items[index].throughput = 0
    }

    func markCancelled(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = .cancelled
        items[index].throughput = 0
    }

    /// The next item that may start, honouring the concurrency limit.
    func nextRunnable() -> TransferItem? {
        guard runningCount < Self.maxConcurrent else { return nil }
        return items.first(where: \.isQueued)
    }
}


/// The set of cancelled transfer ids, readable from any thread.
///
/// The queue is `@MainActor`, so a stored property is main-actor isolated and
/// cannot be read from the nonisolated `isCancelled:` closure the transfer engine
/// polls. This separate reference type is `Sendable` and guards its own state.
final class CancellationFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<UUID> = []

    func set(_ id: UUID) { lock.withLock { ids.insert(id) } }
    func clear(_ id: UUID) { lock.withLock { ids.remove(id) } }
    func contains(_ id: UUID) -> Bool { lock.withLock { ids.contains(id) } }
}
