import AppKit
import UniformTypeIdentifiers
import KRemoteCore

/// Drag-out: hand Finder (or any drop target) the item's actual bytes, fetched
/// only when the item is dropped.
///
/// There is no local copy of a remote file, so a drag cannot hand over an existing
/// URL. `NSItemProvider`'s file representation is AppKit's mechanism for exactly
/// this: the receiver asks for the file after the drop lands, and the download runs
/// into a private temporary directory whose URL is then handed back. Dropping the
/// item back on the same window, or pressing Escape, transfers nothing.
enum SFTPFilePromise {

    /// The UTI the drag advertises. A folder is offered as a folder so the drop
    /// target copies the tree; an unknown extension falls back to plain data
    /// rather than refusing the drag.
    static func contentType(for entry: RemoteEntry) -> UTType {
        if entry.isDirectory { return .folder }
        let ext = (entry.name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return .data }
        return type
    }

    /// Builds the provider for one entry.
    ///
    /// The load handler runs on AppKit's queue when a drop target asks for the
    /// item, so it hops to the main actor to reach `SFTPSession` and reports back
    /// through the handler it was given. A failure hands back the error, which
    /// AppKit shows as a failed drop — never a silent empty file.
    static func provider(for entry: RemoteEntry, session: SFTPSession) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = entry.name
        let type = contentType(for: entry)
        provider.registerFileRepresentation(
            forTypeIdentifier: type.identifier,
            fileOptions: [],
            visibility: .all
        ) { completionHandler in
            let completion = CompletionHandlerBox(completionHandler)
            Task { @MainActor in
                let directory = temporaryDirectory()
                let target = directory.appendingPathComponent(entry.name)
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try await session.downloadDirect(entry, to: target)
                    // `coordinated: false` — this is a plain file the provider
                    // produced itself, not one an NSFileCoordinator is still
                    // writing, so the receiver may copy it straight away.
                    completion.call(target, false, nil)
                } catch {
                    // A half-written drop must not look like a successful copy.
                    try? FileManager.default.removeItem(at: directory)
                    completion.call(nil, false, error)
                }
            }
            // The byte count is unknown until the transfer starts, so the drop
            // shows an indeterminate indicator rather than a fake percentage.
            return Progress(totalUnitCount: -1)
        }
        return provider
    }

    /// A fresh directory for one drop.
    ///
    /// The promised file has to outlive the handler (the receiver copies it after
    /// the handler returns), so it cannot be deleted here; instead stale drop
    /// directories are pruned on the way in, so an afternoon of dragging does not
    /// leave a pile of remote copies in the temporary directory.
    private static func temporaryDirectory() -> URL {
        let root = FileManager.default.temporaryDirectory
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let stale = Date().addingTimeInterval(-3600)
        for url in contents where url.lastPathComponent.hasPrefix("kremote-drag-") {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified < stale {
                try? FileManager.default.removeItem(at: url)
            }
        }
        return root.appendingPathComponent("kremote-drag-\(UUID().uuidString)", isDirectory: true)
    }
}

/// Carries AppKit's non-`Sendable` completion handler into the `Task` above.
///
/// AppKit calls the representation's handler once per drop and the task calls it
/// exactly once, so the unchecked conformance never lets two threads use it at the
/// same time.
private final class CompletionHandlerBox: @unchecked Sendable {
    private let handler: (URL?, Bool, Error?) -> Void

    init(_ handler: @escaping (URL?, Bool, Error?) -> Void) {
        self.handler = handler
    }

    func call(_ file: URL?, _ coordinated: Bool, _ error: Error?) {
        handler(file, coordinated, error)
    }
}
