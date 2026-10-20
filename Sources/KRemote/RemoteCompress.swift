import Foundation
import KRemoteCore

/// Compresses a remote selection **on the server** and downloads the archive.
///
/// Doing it server-side is the whole point: the bytes that cross the network are
/// the compressed ones, the server's CPU does the work next to the data, and
/// nothing is written to this Mac's disk except the final file. Doing it locally
/// would mean downloading everything uncompressed first and then compressing it.
///
/// The archive goes to a temporary file in the server's `/tmp` (or `$TMPDIR`),
/// is streamed straight into the local destination, and is deleted on the server
/// afterwards — including when the transfer fails or the user cancels.
enum RemoteCompress {

    enum Failure: LocalizedError {
        case nothingSelected
        case noTar(String)
        case archiveFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .nothingSelected:
                return "There is nothing to archive."
            case .noTar(let detail):
                return detail.isEmpty
                    ? "The server has no tar command, so it cannot compress files."
                    : "Compressing on the server failed: \(detail)"
            case .archiveFailed(let detail):
                return detail.isEmpty ? "The server could not create the archive." : detail
            case .cancelled:
                return "Compress and download was cancelled."
            }
        }
    }

    /// One shell program: create the archive, print its path, then remove it once
    /// the caller has read it.
    ///
    /// The archive is written into a private directory in the server's temp space
    /// with `mkdtemp`, so two windows compressing at once cannot collide and a
    /// leftover file cannot be read by another user of the host.
    static func script(paths: [String], archiveName: String) -> String {
        let quoted = paths.map(ShellQuote.single).joined(separator: " ")
        let name = ShellQuote.single(archiveName)
        // Streams, in order: tar's diagnostics on stderr, the archive on stdout.
        // `set -e` would abort on tar's first complaint, so it is deliberately off
        // and the exit status is checked by the caller through stderr.
        return """
        d=$(mktemp -d "${TMPDIR:-/tmp}/kremote.XXXXXX") || exit 1
        a="$d"/\(name)
        printf '%s %s\n' "$d" "" >&2
        tar -czf "$a" -- \(quoted)
        rc=$?
        if [ $rc -ne 0 ]; then rm -rf "$d"; exit $rc; fi
        cat "$a"
        rc=$?
        rm -rf "$d"
        exit $rc
        """
    }

    /// The command that deletes the temporary directory once the download is done.
    static func cleanupScript(directory: String) -> String {
        "rm -rf " + ShellQuote.single(directory)
    }

    /// Runs the archive on the server and streams it into `destination`.
    ///
    /// - Parameter progress: bytes received so far. The compressed size is not
    ///   known up front, so the second argument is nil.
    static func run(
        entries: [RemoteEntry],
        shell: RemoteShell,
        destination: URL,
        progress: (@Sendable (Int64, Int64?) -> Void)? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws {
        guard !entries.isEmpty else { throw Failure.nothingSelected }

        let fileManager = FileManager.default
        let part = destination.appendingPathExtension("part")
        try? fileManager.removeItem(at: part)
        fileManager.createFile(atPath: part.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: part.path) else {
            throw Failure.archiveFailed("Could not create \(part.lastPathComponent).")
        }

        let counter = ReceivedCounter()
        var archivePath: String?

        do {
            // Unprivileged first: most selections are readable, and sudo is a
            // second login that should not be paid for when it is not needed.
            var output: RemoteShell.Output
            do {
                output = try await stream(
                    shell: shell,
                    elevated: false,
                    entries: entries,
                    handle: handle,
                    counter: counter,
                    progress: progress,
                    isCancelled: isCancelled
                )
            } catch {
                // Only a refusal is worth retrying as root: a timeout or a broken
                // pipe fails the same way and would just cost another login.
                guard Self.isPermissionDenied(error) else { throw error }
                output = try await stream(
                    shell: shell,
                    elevated: true,
                    entries: entries,
                    handle: handle,
                    counter: counter,
                    progress: progress,
                    isCancelled: isCancelled
                )
            }
            try? handle.close()

            // stdout carries only the archive; stderr's first line is the temp
            // directory the script made, and anything else there is tar talking.
            archivePath = output.stderr
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { $0.hasPrefix("/") }

            if isCancelled() { throw Failure.cancelled }
            if counter.value == 0 {
                let detail = output.stderr
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.hasPrefix("/") }
                    .joined(separator: " ")
                throw Failure.archiveFailed(detail)
            }

            // Rename into place only after the whole archive arrived: a partial
            // file must never look like a finished one.
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: part, to: destination)
        } catch {
            try? handle.close()
            try? fileManager.removeItem(at: part)
            throw error
        }

        // Best effort: the server's copy is useless either way, and a failure here
        // must not turn a completed download into an error.
        if let directory = archivePath.map({ ($0 as NSString).deletingLastPathComponent }) {
            _ = try? await shell.run(cleanupScript(directory: directory), timeout: 30)
        }
    }


    /// One attempt at archiving, privileged or not. The archive bytes go straight
    /// into `handle`; the script's temp directory is reported on stderr.
    private static func stream(
        shell: RemoteShell,
        elevated: Bool,
        entries: [RemoteEntry],
        handle: FileHandle,
        counter: ReceivedCounter,
        progress: (@Sendable (Int64, Int64?) -> Void)?,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> RemoteShell.Output {
        let command = script(paths: entries.map(\.path), archiveName: suggestedName(for: entries))
        let consume: @Sendable (Data) -> Void = { chunk in
            if isCancelled() { return }
            try? handle.write(contentsOf: chunk)
            progress?(counter.add(Int64(chunk.count)), nil)
        }
        return elevated
            ? try await shell.runElevated(command, timeout: 3600, consume: consume)
            : try await shell.run(command, timeout: 3600, consume: consume)
    }

    /// True when the failure is the server refusing to read a path, which is the
    /// only case elevation can fix.
    static func isPermissionDenied(_ error: Error) -> Bool {
        let text = ((error as? LocalizedError)?.errorDescription ?? String(describing: error))
            .lowercased()
        return text.contains("permission denied")
            || text.contains("cannot stat")
            || text.contains("cannot open")
    }

    /// A name for the archive: the single item's, or a dated "Selection".
    static func suggestedName(for entries: [RemoteEntry], date: Date = Date()) -> String {
        if entries.count == 1, let only = entries.first {
            let base = (only.name as NSString).deletingPathExtension
            return (base.isEmpty ? only.name : base) + ".tar.gz"
        }
        let formatter = Foundation.DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "Selection \(formatter.string(from: date)).tar.gz"
    }
}


/// A byte counter the streaming closure can share safely.
final class ReceivedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64 = 0

    var value: Int64 { lock.withLock { total } }

    @discardableResult
    func add(_ bytes: Int64) -> Int64 {
        lock.withLock {
            total += bytes
            return total
        }
    }
}
