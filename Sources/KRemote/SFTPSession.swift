import Foundation
import Observation
import KRemoteCore

/// One open SFTP window: a live client bound to a connection node.
///
/// The window owns this object; closing the window disconnects the client. The
/// model keeps no SFTP state of its own beyond the list of open sessions, so a
/// connection's terminal and its file browser stay independent.
@MainActor
@Observable
final class SFTPSession: Identifiable {
    let id = UUID()
    let nodeID: ConnectionNode.ID

    /// Name shown in the window title.
    private(set) var title: String

    /// Where the browser is looking. Always absolute once connected.
    private(set) var path: String = "~"
    private(set) var entries: [RemoteEntry] = []
    private(set) var isLoading = false
    /// Set when the last operation failed; shown inline with the server's text.
    /// Writable so the window can surface a local notice (e.g. an unimplemented
    /// gesture) without pretending the server said it.
    var errorMessage: String?
    /// True once the handshake with the server has completed.
    private(set) var isConnected = false

    /// Navigation history for ⌘[ / ⌘].
    private var history: [String] = []
    private var historyIndex = -1

    let client: SFTPClient
    /// How the connection was resolved, for the status bar.
    let target: String

    init(nodeID: ConnectionNode.ID, title: String, client: SFTPClient, target: String) {
        self.nodeID = nodeID
        self.title = title
        self.client = client
        self.target = target
    }

    // MARK: - Connection

    func connect() async {
        guard !isConnected else { return }
        isLoading = true
        errorMessage = nil
        do {
            try await client.connect()
            isConnected = true
            // Start at the login user's home directory, resolved by the server.
            let home = try await client.realpath(".")
            path = home
            visit(home, resetHistory: true)
            await reload()
        } catch {
            errorMessage = Self.describe(error)
        }
        isLoading = false
    }

    /// Reopens the transport after a failure (the sheet's "Reconnect").
    func reconnect() async {
        client.disconnect()
        isConnected = false
        await connect()
    }

    func disconnect() {
        client.disconnect()
        isConnected = false
    }

    // MARK: - Navigation

    func reload() async {
        guard isConnected, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            entries = try await client.list(path)
            errorMessage = nil
        } catch {
            entries = []
            errorMessage = Self.describe(error)
        }
    }

    func enter(_ entry: RemoteEntry) {
        guard entry.isDirectory else { return }
        visit(entry.path)
        Task { await reload() }
    }

    func go(to destination: String) {
        let target = destination.hasPrefix("/") || destination.hasPrefix("~")
            ? destination
            : SFTPClient.join(path, destination)
        visit(target)
        Task { await reload() }
    }

    func goUp() {
        let parent = SFTPClient.parent(of: path)
        guard parent != path else { return }
        visit(parent)
        Task { await reload() }
    }

    var canGoUp: Bool { path != "/" }

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex >= 0 && historyIndex < history.count - 1 }

    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        path = history[historyIndex]
        Task { await reload() }
    }

    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        path = history[historyIndex]
        Task { await reload() }
    }

    /// Records a visit, truncating any forward history — the same rule every
    /// browser uses, so back/forward never points at a branch you left.
    private func visit(_ destination: String, resetHistory: Bool = false) {
        let normalised = SFTPClient.normalise(destination)
        if resetHistory {
            history = [normalised]
            historyIndex = 0
        } else if historyIndex >= 0, history[safe: historyIndex] == normalised {
            return
        } else {
            history = Array(history.prefix(historyIndex + 1))
            history.append(normalised)
            historyIndex = history.count - 1
        }
        path = normalised
    }

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

    /// Shortcuts shown in the sidebar. Only paths the server actually has are
    /// offered, so a Linux box does not get a `/Volumes` that cannot exist.
    var shortcuts: [(name: String, path: String, icon: String)] {
        [
            ("Home", "~", "house"),
            ("Root", "/", "internaldrive"),
            ("tmp", "/tmp", "folder.badge.gearshape"),
        ]
    }

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
