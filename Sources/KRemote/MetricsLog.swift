import Foundation
import KRemoteCore

/// A small append-only log for the metrics path.
///
/// The badge is invisible when sampling fails, so without this a failure is
/// indistinguishable from a feature that is not wired up — which is exactly the
/// report that came back. Lines land next to `perf.log`:
/// `~/Library/Application Support/KRemote/metrics.log`.
enum MetricsLog {
    private static let queue = DispatchQueue(label: "com.emircankavas.kremote.metrics-log")

    static func record(_ message: String) {
        queue.async {
            let base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let directory = base.appendingPathComponent("KRemote", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("metrics.log")

            let stamp = ISO8601DateFormatter().string(from: Date())
            let line = "[\(stamp)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }

            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                // Keep the file from growing without bound across a long day.
                if let size = try? handle.seekToEnd(), size > 200_000 {
                    try? handle.truncate(atOffset: 0)
                }
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
