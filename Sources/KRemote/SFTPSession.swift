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
    private var client: SFTPClient

    /// Navigation history for ⌘[ / ⌘].
    private var history: [String] = []
    private var historyIndex = -1

    /// Rises with every listing. A reply that arrives after the user navigated
    /// again is dropped instead of overwriting the newer directory.
    private var loadToken = 0
    private var homePath = "~"

    init(
        nodeID: ConnectionNode.ID,
        title: String,
        target: String,
        makeClient: @escaping () -> SFTPClient
    ) {
        self.nodeID = nodeID
        self.title = title
        self.target = target
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
            errorMessage = nil
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
        visit(target)
        await load()
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
