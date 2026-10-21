import Foundation
import Observation
import KRemoteCore

/// One open SFTP window: a live client bound to a connection node.
///
/// The window owns this object; closing the window disconnects the client. All
/// server I/O goes through `SFTPClient`, whose methods are nonisolated `async`,
/// so a listing never runs on the main actor; every mutation of observable
/// state comes back here.
@MainActor
@Observable
final class SFTPSession: Identifiable {
    /// A folder in the window's sidebar.
    struct Shortcut: Identifiable, Hashable {
        let name: String
        let path: String
        let icon: String
        var id: String { path }
    }

    let id = UUID()
    let nodeID: ConnectionNode.ID

    /// Connection name — the window title.
    let title: String
    /// `user@host:port`, shown in the status bar.
    let target: String

    /// Where the browser is looking. `~` until the handshake resolves the home
    /// directory; always absolute after that.
    private(set) var path: String = "~"
    /// Everything the last listing returned, dot-files included. Filtering and
    /// sorting are the views' business.
    private(set) var entries: [RemoteEntry] = []

    private(set) var isConnecting = false
    private(set) var isLoading = false
    /// True once the version handshake has completed.
    private(set) var isConnected = false
    /// Set when an operation failed; always carries the server's own text.
    var errorMessage: String?

    /// The window's transfer queue. Owned here so a window close can cancel
    /// everything still in flight instead of leaving an ssh process writing.
    let transfers = TransferQueue()

    /// Set while a file operation (rename, delete, chmod, new folder) is running,
    /// so the toolbar can disable the actions that would collide with it.
    private(set) var isBusy = false

    /// Everything the browser knows about the connection for wording a failure:
    /// whether sudo is set up is the client's business, not the view's.
    var elevationContext: OperationFailureText.Context {
        OperationFailureText.Context(elevation: client.elevationAvailability)
    }

    /// Sidebar folders: Home/Root/tmp plus whatever mount roots the server has.
    private(set) var shortcuts: [Shortcut] = [
        Shortcut(name: "Home", path: "~", icon: "house"),
        Shortcut(name: "Root", path: "/", icon: "internaldrive"),
        Shortcut(name: "tmp", path: "/tmp", icon: "folder.badge.gearshape"),
    ]

    /// Builds a fresh client. `reconnect` needs one: an `SFTPClient` is
    /// single-shot — once its ssh process is gone the object cannot be reused.
    /// Called only from this (main-actor) object, so it is not `@Sendable`: the
    /// builder reads credentials and the sudo flag from `AppModel`.
    private let makeClient: () -> SFTPClient
    /// The live client. Exposed so "Compress and download" can reuse the download
    /// path — a second connection would re-authenticate and could see a different
    /// tree if the server is being written to.
    var sftpClient: SFTPClient { client }

    /// Opens a shell channel on the same server, for work SFTP v3 cannot ask for
    /// (compressing a selection into one archive). A second ssh connection, not a
    /// second SFTP session: the subsystem has no way to run a program.
    /// Whether this connection can elevate at all. The window reads it to say why
    /// an archive failed rather than offering a retry that cannot work.
    var canElevate: Bool { client.elevationAvailability.isAvailable }

    /// The sudo provider used by both the SFTP retry and the elevated shell.
    private func makeElevation() -> ElevationProvider? { elevation }

    func makeShell() -> RemoteShell {
        RemoteShell(
            host: connection.host,
            port: connection.port,
            username: connection.username,
            identityFile: connection.identityFile,
            password: connection.password,
            elevation: makeElevation()
        )
    }

    private var client: SFTPClient

    /// Navigation history for ⌘[ / ⌘].
    private var history: [String] = []
    private var historyIndex = -1

    /// Rises with every listing. A reply that arrives after the user navigated
    /// again is dropped instead of overwriting the newer directory.
    private var loadToken = 0
    private var homePath = "~"

    /// The SSH settings, kept so a shell channel can be opened on demand.
    struct Connection: Sendable {
        let host: String
        let port: Int
        let username: String
        let identityFile: String
        let password: String
    }

    private let connection: Connection
    /// The sudo provider shared by the SFTP retry and the elevated shell.
    private let elevation: ElevationProvider?

    init(
        nodeID: ConnectionNode.ID,
        title: String,
        target: String,
        connection: Connection,
        elevation: ElevationProvider?,
        makeClient: @escaping () -> SFTPClient
    ) {
        self.nodeID = nodeID
        self.title = title
        self.target = target
        self.connection = connection
        self.elevation = elevation
        self.makeClient = makeClient
        self.client = makeClient()
    }

    // MARK: - Connection

    /// Opens the transport and shows the login user's home directory.
    ///
    /// Bounded by ssh itself: the transport is built with `ConnectTimeout` and
    /// `ServerAlive*` (see `ProcessSFTPTransport`), because a blocked pipe read
    /// cannot be interrupted from Swift — a `Task` timeout around it would hang
    /// just the same. A black-holed host therefore fails with ssh's own message
    /// instead of a permanent "Connecting…".
    func connect() async {
        guard !isConnected, !isConnecting else { return }
        isConnecting = true
        isLoading = true
        errorMessage = nil
        do {
            try await client.connect()
            isConnected = true
            // The home directory is the server's answer, never a guess at $HOME.
            let home = try await client.realpath(".")
            homePath = home
            shortcuts[0] = Shortcut(name: "Home", path: home, icon: "house")
            resetHistory(to: home)
            await load()
            await probeMounts()
        } catch {
            // Terminating the child closes the pipes, so nothing is left running
            // behind a failed connect.
            client.disconnect()
            isConnected = false
            errorMessage = Self.describe(error)
        }
        isLoading = false
        isConnecting = false
    }

    /// The window shows this while the handshake runs, so a slow server is
    /// visibly working rather than indistinguishable from a hang, and the user
    /// can stop waiting.
    func cancelConnect() {
        client.disconnect()
        isConnecting = false
        isLoading = false
        isConnected = false
        errorMessage = "Connection cancelled."
    }

    /// Reopens the transport — the Retry behind every error state. The dead
    /// client is replaced rather than reused, because its ssh process is gone.
    func reconnect() async {
        client.disconnect()
        client = makeClient()
        isConnected = false
        isConnecting = false
        isLoading = false
        await connect()
    }

    func disconnect() {
        client.disconnect()
        isConnected = false
        isConnecting = false
        isLoading = false
    }

    // MARK: - Listing

    /// Re-reads the current directory.
    func load() async {
        guard isConnected else { return }
        loadToken += 1
        let token = loadToken
        isLoading = true
        do {
            let listing = try await client.list(path)
            guard token == loadToken else { return }
            entries = listing
            // Deliberately does not clear `errorMessage`: after a refused folder
            // the browser returns to the previous one and reloads it, and the
            // successful reload used to erase the reason a runloop later. The
            // message is cleared when a *new* navigation starts, or dismissed.
        } catch {
            guard token == loadToken else { return }
            entries = []
            errorMessage = Self.describe(error)
            // A dead transport cannot be reused; the error state's Retry builds
            // a fresh client instead of pretending the old one still works.
            if case .connectionClosed = error as? SFTPError ?? .invalidArgument("") {
                isConnected = false
            }
        }
        if token == loadToken { isLoading = false }
    }

    // MARK: - Navigation

    /// Double-click / Return on a row. A file is a no-op in this card; card 5
    /// wires open and download.
    /// The row the user last picked, so Return can act on it.
    var selectedPath: String?

    /// Opens the selected folder (Return / ⌘↓), the Finder behaviour.
    func openSelection() async {
        guard let selectedPath,
              let entry = entries.first(where: { $0.path == selectedPath }) else { return }
        await open(entry)
    }

    func open(_ entry: RemoteEntry) async {
        guard entry.isDirectory else { return }
        await go(to: entry.path)
    }

    func go(to destination: String) async {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let target: String
        if trimmed == "~" {
            target = homePath
        } else if trimmed.hasPrefix("/") {
            target = SFTPClient.normalise(trimmed)
        } else {
            target = SFTPClient.join(path, trimmed)
        }
        let previous = path
        errorMessage = nil
        visit(target)
        await load()
        // A directory that could not be read must not leave the browser sitting
        // in it with an empty list: that reads as "the app broke". Go back to the
        // folder that worked and keep the server's message on screen.
        if errorMessage != nil, entries.isEmpty, path != previous {
            visit(previous)
            await load()
        }
    }

    func goUp() async {
        let parent = SFTPClient.parent(of: path)
        guard parent != path else { return }
        visit(parent)
        await load()
    }

    var canGoUp: Bool { path != "/" }

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex >= 0 && historyIndex < history.count - 1 }

    func goBack() async {
        guard canGoBack else { return }
        historyIndex -= 1
        path = history[historyIndex]
        await load()
    }

    func goForward() async {
        guard canGoForward else { return }
        historyIndex += 1
        path = history[historyIndex]
        await load()
    }

    /// Records a visit, truncating any forward history — the rule every browser
    /// uses, so back/forward never points at a branch the user left.
    private func visit(_ destination: String) {
        let normalised = SFTPClient.normalise(destination)
        if historyIndex >= 0, history[safe: historyIndex] == normalised {
            path = normalised
            return
        }
        history = Array(history.prefix(historyIndex + 1))
        history.append(normalised)
        historyIndex = history.count - 1
        path = normalised
    }

    private func resetHistory(to destination: String) {
        let normalised = SFTPClient.normalise(destination)
        history = [normalised]
        historyIndex = 0
        path = normalised
    }

    // MARK: - Breadcrumbs

    /// Breadcrumb components, each with the absolute path that leads to it.
    var breadcrumbs: [(name: String, path: String)] {
        guard path.hasPrefix("/") else { return [(path, path)] }
        var result: [(String, String)] = [("/", "/")]
        var accumulated = ""
        for component in path.split(separator: "/") {
            accumulated += "/" + component
            result.append((String(component), accumulated))
        }
        return result
    }

    /// Mount roots the server actually exposes, appended to the sidebar:
    /// `/Volumes` children on macOS, `/mnt` and `/media` on Linux. Probed once,
    /// so a Linux box is never offered a `/Volumes` that cannot exist.
    private func probeMounts() async {
        var mounts: [Shortcut] = []
        for root in ["/Volumes", "/mnt", "/media"] {
            guard let children = try? await client.list(root) else { continue }
            for child in children where child.isDirectory {
                mounts.append(Shortcut(name: child.name, path: child.path, icon: "externaldrive"))
            }
        }
        guard !mounts.isEmpty else { return }
        shortcuts = Array(shortcuts.prefix(3)) + mounts
    }

    // MARK: - File operations

    /// Creates a folder in the current directory and returns its path so the view
    /// can select it.
    @discardableResult
    func createFolder(named name: String) async -> Result<String, OperationError> {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidName(trimmed) else { return .failure(OperationError(name: trimmed, error: InvalidName())) }
        let destination = SFTPClient.join(path, trimmed)
        do {
            try await client.mkdir(destination)
            await load()
            return .success(destination)
        } catch {
            return .failure(OperationError(name: trimmed, error: error))
        }
    }

    /// Renames one entry in place. `newName` is a name, not a path.
    func rename(_ entry: RemoteEntry, to newName: String) async -> Result<String, OperationError> {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidName(trimmed) else { return .failure(OperationError(name: entry.name, error: InvalidName())) }
        guard trimmed != entry.name else { return .success(entry.path) }
        let destination = SFTPClient.join(SFTPClient.parent(of: entry.path), trimmed)
        do {
            try await client.rename(entry.path, to: destination)
            await load()
            return .success(destination)
        } catch {
            return .failure(OperationError(name: entry.name, error: error))
        }
    }

    /// Deletes a whole selection in one pass, reporting which items worked.
    ///
    /// One summary, not one alert per item — that is the batch rule the card sets
    /// out. A failure on one item does not stop the others.
    func delete(_ entries: [RemoteEntry]) async -> BatchOutcome {
        var outcome = BatchOutcome()
        isBusy = true
        defer { isBusy = false }
        for entry in entries {
            if Task.isCancelled {
                outcome.wasCancelled = true
                outcome.skipped.append(entry.name)
                continue
            }
            do {
                _ = try await client.removeRecursively(entry.path)
                outcome.recordSuccess(entry.name)
            } catch {
                outcome.recordFailure(entry.name, error: error)
            }
        }
        await load()
        return outcome
    }

    /// How many items a delete of `entry` would remove: 1 for a file, the tree's
    /// size for a folder. Shows a spinner-worthy wait only on big trees, so the
    /// confirmation names a real number instead of "all contents".
    func deleteCount(for entry: RemoteEntry) async -> Int? {
        guard entry.isDirectory, !entry.isSymlink else { return 1 }
        return try? await client.countItems(in: entry.path)
    }

    /// Applies a permissions sheet. One entry at a time so a refusal is reported
    /// per item, and the row is refreshed on success.
    func applyPermissions(
        _ set: PermissionSet,
        owner: UInt32?,
        group: UInt32?,
        to entries: [RemoteEntry]
    ) async -> BatchOutcome {
        var outcome = BatchOutcome()
        isBusy = true
        defer { isBusy = false }
        for entry in entries {
            do {
                try await client.setAttributes(
                    entry.path,
                    permissions: set.modeBits,
                    uid: owner,
                    gid: group
                )
                outcome.recordSuccess(entry.name)
            } catch {
                outcome.recordFailure(entry.name, error: error)
            }
        }
        await load()
        return outcome
    }

    /// `stat` with the link itself, for the Show Info sheet.
    func info(for entry: RemoteEntry) async -> SFTPAttributes? {
        try? await client.stat(entry.path, followSymlinks: false)
    }

    /// The human-readable size of a selection, for the status bar: files are
    /// summed, folders are counted separately because their true size is a tree
    /// walk the status bar must not perform on every selection change.
    func selectionSummary(_ selection: Set<String>, rows: [RemoteEntry]) -> (count: Int, bytes: UInt64, folders: Int) {
        let selected = rows.filter { selection.contains($0.path) }
        let files = selected.filter { !$0.isDirectory }
        return (
            selected.count,
            files.reduce(UInt64(0)) { $0 + ($1.size ?? 0) },
            selected.count - files.count
        )
    }

    /// A name is usable when it is not empty, not a path, and not `.` or `..`.
    func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0") else { return false }
        return name != "." && name != ".."
    }

    // MARK: - Transfers

    /// Downloads one entry straight to an exact local URL, outside the queue's
    /// conflict logic.
    ///
    /// A drag promise names its own destination (the drop target chose it), so
    /// there is nothing to ask the user and no batch to report. Failures propagate
    /// to AppKit, which shows the drop as failed.
    func downloadDirect(_ entry: RemoteEntry, to localURL: URL) async throws {
        let client = self.client
        if entry.isDirectory {
            try await client.downloadTree(entry.path, to: localURL)
        } else {
            try await client.downloadFile(entry.path, to: localURL)
        }
    }

    /// Queues downloads with already-resolved destinations.
    ///
    /// The window resolves conflicts (Replace / Keep Both / Skip) *before* this
    /// call, so the queue never has to ask a question mid-batch.
    func enqueueDownload(_ items: [(entry: RemoteEntry, destination: URL)]) {
        guard !items.isEmpty else { return }
        for item in items {
            transfers.enqueueDownload(
                name: item.destination.lastPathComponent,
                remotePath: item.entry.path,
                localURL: item.destination
            )
        }
        transfers.isExpanded = true
        startTransfers()
    }

    /// Uploads local URLs (files or folders) into a remote directory.
    func enqueueUpload(_ urls: [URL], into directory: String? = nil) {
        let destinationDirectory = directory ?? path
        var queued = false
        for url in urls {
            let destination = SFTPClient.join(destinationDirectory, url.lastPathComponent)
            transfers.enqueueUpload(
                name: url.lastPathComponent,
                remotePath: destination,
                localURL: url
            )
            queued = true
        }
        guard queued else { return }
        transfers.isExpanded = true
        startTransfers()
    }

    /// Runs queued transfers up to the queue's concurrency limit.
    ///
    /// Each item gets its own `Task`, so a slow 200 MB upload does not hold the
    /// others back and a failure cannot cancel its neighbours. The loop starts
    /// every item the queue allows and returns; finished tasks start the next.
    func startTransfers() {
        while let item = transfers.nextRunnable() {
            transfers.markRunning(item.id)
            let id = item.id
            let kind = item.kind
            let remotePath = item.remotePath
            let localURL = item.localURL
            let queue = transfers
            let client = self.client

            Task { [weak self] in
                do {
                    switch kind {
                    case .download:
                        guard let localURL else { throw SFTPError.invalidArgument("no local destination") }
                        try await Self.runDownload(
                            client: client, remotePath: remotePath, localURL: localURL, id: id, queue: queue
                        )
                    case .upload:
                        guard let localURL else { throw SFTPError.invalidArgument("no local source") }
                        try await Self.runUpload(
                            client: client, localURL: localURL, remotePath: remotePath, id: id, queue: queue
                        )
                    case .internalCopy:
                        guard let localURL else { throw SFTPError.invalidArgument("no local destination") }
                        try await Self.runDownload(
                            client: client, remotePath: remotePath, localURL: localURL, id: id, queue: queue
                        )
                    }
                    queue.markFinished(id)
                } catch is TransferCancelled {
                    queue.markCancelled(id)
                } catch {
                    queue.markFailed(id, reason: OperationFailureText.describe(error))
                }
                await self?.refreshAfterTransfer()
            }
        }
    }

    /// Downloads, treating a remote directory as a tree.
    private static func runDownload(
        client: SFTPClient, remotePath: String, localURL: URL, id: UUID, queue: TransferQueue
    ) async throws {
        let attributes = try await client.stat(remotePath, followSymlinks: false)
        if attributes.isDirectory {
            try await client.downloadTree(remotePath, to: localURL, progress: { tick in
                Task { @MainActor in queue.updateProgress(id, progress: tick) }
            }, isCancelled: {
                queue.isCancelled(id)
            })
        } else {
            try await client.downloadFile(remotePath, to: localURL, progress: { tick in
                Task { @MainActor in queue.updateProgress(id, progress: tick) }
            }, isCancelled: {
                queue.isCancelled(id)
            })
        }
    }

    /// Uploads, treating a local directory as a tree.
    private static func runUpload(
        client: SFTPClient, localURL: URL, remotePath: String, id: UUID, queue: TransferQueue
    ) async throws {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            try await client.uploadTree(from: localURL, to: remotePath, progress: { tick in
                Task { @MainActor in queue.updateProgress(id, progress: tick) }
            }, isCancelled: {
                queue.isCancelled(id)
            })
        } else {
            try await client.uploadFile(localURL, to: remotePath, progress: { tick in
                Task { @MainActor in queue.updateProgress(id, progress: tick) }
            }, isCancelled: {
                queue.isCancelled(id)
            })
        }
    }

    /// A finished transfer changed the directory: refresh it so the new file is
    /// visible without the user pressing ⌘R.
    private func refreshAfterTransfer() async {
        if transfers.runningCount > 0 || transfers.queuedCount > 0 {
            startTransfers()
            return
        }
        await load()
    }

    /// Cancels every transfer, for a window that is closing: an ssh process left
    /// writing is worse than a cancelled download.
    func cancelTransfers() {
        for item in transfers.items where item.isQueued || item.isRunning {
            transfers.cancel(item.id)
        }
    }

    // MARK: - Rows the views draw

    /// Filters and sorts the current listing — one implementation for both
    /// views and for tests.
    ///
    /// Directories always come first (Finder's rule); then the chosen column,
    /// ascending or descending, with ties broken by name so a sort never
    /// shuffles equal rows around.
    func rows(
        showHidden: Bool,
        sortColumn: SFTPSortColumn = .name,
        ascending: Bool = true
    ) -> [RemoteEntry] {
        let filtered = showHidden ? entries : entries.filter { !$0.name.hasPrefix(".") }
        return filtered.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let comparison: ComparisonResult
            switch sortColumn {
            case .name:
                comparison = a.name.localizedStandardCompare(b.name)
            case .size:
                comparison = Self.compare(a.size ?? 0, b.size ?? 0, a.name, b.name)
            case .modified:
                comparison = Self.compare(
                    a.modified?.timeIntervalSince1970 ?? 0,
                    b.modified?.timeIntervalSince1970 ?? 0,
                    a.name, b.name
                )
            case .permissions:
                comparison = Self.compare(a.permissions ?? 0, b.permissions ?? 0, a.name, b.name)
            case .owner:
                comparison = Self.compare(
                    a.attributes.uid ?? 0, b.attributes.uid ?? 0, a.name, b.name
                )
            }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    private static func compare<T: Comparable>(
        _ a: T, _ b: T, _ nameA: String, _ nameB: String
    ) -> ComparisonResult {
        if a == b { return nameA.localizedStandardCompare(nameB) }
        return a < b ? .orderedAscending : .orderedDescending
    }

    // MARK: - Embedded editor

    /// Reads a file for the editor, with the metadata the conflict check needs.
    ///
    /// `readFile` and `stat` are separate round trips to the same path; a file edited
    /// between them would carry an mtime from after the read, making the next save look
    /// like somebody else's change. Reading first and then statting means the timestamp
    /// is never older than the bytes, which fails safe: a spurious conflict prompt is
    /// recoverable, a silent overwrite is not.
    func loadFile(_ path: String) async throws -> (data: Data, size: UInt64?, modified: Date?) {
        let data = try await client.readFile(path)
        let attributes = try? await client.stat(path)
        return (data, attributes?.size, attributes?.modified)
    }

    func fileInfo(_ path: String) async throws -> (size: UInt64?, modified: Date?) {
        let attributes = try await client.stat(path)
        return (attributes.size, attributes.modified)
    }

    /// Writes text back to the server.
    ///
    /// Permissions of an existing file are preserved: `writeFile` opens with 0o644 on
    /// create, which would turn a 0600 key file into world-readable on save. The mode is
    /// captured from the server first and restored afterwards.
    func saveFile(_ path: String, text: String) async throws {
        let existing = try? await client.stat(path)
        try await client.writeFile(path, data: Data(text.utf8))
        if let mode = existing?.permissions {
            // Mode bits only: `st_mode` carries the file-type bits too, and setting
            // those back is a permission change nobody asked for.
            try? await client.setPermissions(path, permissions: UInt16(mode & 0o7777))
        }
    }

    // MARK: - Display helpers

    /// The server's own words where there are any — never a generic "failed".
    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
