import Foundation
import Observation
import KRemoteCore

/// An open remote session: one live SSH connection shown in a tab.
struct Session: Identifiable, Hashable {
    let id: UUID
    let nodeID: ConnectionNode.ID
    /// User-facing name (falls back to the node name; may be replaced by the
    /// remote title via OSC 0/2).
    var title: String
    /// Set from the terminal's title escape; nil = keep `title`.
    var remoteTitle: String?
    /// Bumped to force the terminal view to be torn down and rebuilt — used by
    /// "Reconnect" to start a fresh ssh process.
    var generation: Int

    init(id: UUID = UUID(), nodeID: ConnectionNode.ID, title: String, generation: Int = 0) {
        self.id = id
        self.nodeID = nodeID
        self.title = title
        self.generation = generation
    }

    var displayTitle: String { remoteTitle ?? title }

    static func == (lhs: Session, rhs: Session) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor
@Observable
final class AppModel {
    /// Root of the connection tree.
    private(set) var roots: [ConnectionNode] = []

    /// Currently highlighted row in the sidebar. Drives where new items go and
    /// which node the editor sheet edits.
    var selectedNodeID: ConnectionNode.ID?

    /// Set to a node id to present the editor sheet. `ConnectionEditorView`
    /// observes this and loads the node's draft.
    var editingNodeID: ConnectionNode.ID?

    /// Open session tabs, in order.
    var sessions: [Session] = []
    var activeSessionID: Session.ID?

    /// Surfaced in the UI when load/save/Keychain fails; not fatal.
    var lastError: String?

    /// Set when a live RDP session needs credentials the tree did not have (or
    /// that the server rejected). The pane presents a sheet and answers through
    /// `supplyRDPCredentials` / `cancelRDPCredentials`.
    var pendingRDPLogin: RDPCredentialRequest?

    /// How the answer reaches the RDP client whose session thread is waiting.
    /// Set by the pane while it owns the live session; cleared once answered.
    var rdpCredentialAnswer: ((RDPCredentialAnswer) -> Void)?

    private let store: NodeStore
    private let secrets: SecretStore

    // MARK: - Snippets

    /// The user's script library, in menu order.
    private(set) var snippets: [Snippet] = []
    /// Set to a snippet's id to present its editor.
    var editingSnippetID: Snippet.ID?
    /// Set to present a blank editor for a new snippet.
    var isCreatingSnippet = false

    /// A snippet waiting for confirmation, and the session it would run on.
    ///
    /// Holding the *session* here rather than reading focus at run time matters: the
    /// confirmation sheet can steal focus, and a script must never land in a pane the
    /// user did not aim at.
    var pendingSnippet: PendingSnippet?

    struct PendingSnippet: Identifiable {
        let id = UUID()
        let snippet: Snippet
        let sessionID: Session.ID
        /// Which surface the command goes to, so the terminal can pick it up.
        let request: Int
    }

    /// Bumped per request so a repeat of the same snippet is still a new event.
    private var snippetRequestCounter = 0

    private let snippetStore: SnippetStore

    init(
        store: NodeStore = .defaultStore(),
        secrets: SecretStore? = nil,
        snippetStore: SnippetStore = .defaultStore()
    ) {
        self.store = store
        self.secrets = secrets ?? EncryptedSecretStore.defaultStore()
        self.snippetStore = snippetStore
        load()
        loadSnippets()
        migrateLegacyKeychainIfNeeded()
    }

    /// Reads the snippet library. A broken file must not stop the app from opening,
    /// so the failure is surfaced and the library comes up empty.
    func loadSnippets() {
        do {
            snippets = (try snippetStore.load() ?? []).sorted(by: Self.snippetOrder)
        } catch {
            lastError = "Could not load snippets: \(error)"
            snippets = []
        }
    }

    /// Menu order: explicit index, then name, so the order the user arranged survives.
    static func snippetOrder(_ a: Snippet, _ b: Snippet) -> Bool {
        a.sortIndex == b.sortIndex
            ? a.name.localizedStandardCompare(b.name) == .orderedAscending
            : a.sortIndex < b.sortIndex
    }

    private func saveSnippets() {
        do {
            try snippetStore.save(snippets)
        } catch {
            lastError = "Could not save snippets: \(error)"
        }
    }

    /// Adds or replaces a snippet and persists.
    func upsertSnippet(_ snippet: Snippet) {
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[index] = snippet
        } else {
            snippets.append(snippet)
        }
        snippets.sort(by: Self.snippetOrder)
        saveSnippets()
    }

    func deleteSnippet(_ id: Snippet.ID) {
        snippets.removeAll { $0.id == id }
        saveSnippets()
    }

    /// Asks to run `snippet` on the focused SSH session.
    ///
    /// Nothing runs from here: the question is asked first, and `confirmSnippet` is
    /// what reaches the terminal. RDP and non-SSH sessions have no shell to send to,
    /// so the menu item is disabled rather than failing silently.
    func requestSnippet(_ snippet: Snippet) {
        guard let session = focusedSession,
              let node = find(session.nodeID), node.supportsSSH else {
            lastError = "Snippets run in an SSH session. Open one first."
            return
        }
        snippetRequestCounter += 1
        pendingSnippet = PendingSnippet(
            snippet: snippet,
            sessionID: session.id,
            request: snippetRequestCounter
        )
    }

    /// The user said yes: hand the command to the terminal in that session.
    func confirmSnippet() {
        guard let pending = pendingSnippet else { return }
        pendingSnippet = nil
        snippetTarget = pending.sessionID
        snippetRequest = pending.request
        // A marker first, so the user's scrollback shows which snippet ran. It is a
        // shell comment: it cannot execute, cannot be a syntax error in any POSIX sh,
        // and stays visible above the script's own output.
        let marker = "# KRemote snippet: " + pending.snippet.name
            .replacingOccurrences(of: "\n", with: " ")
        snippetCommand = marker + "\n" + SnippetLibrary.command(for: pending.snippet)
    }

    func cancelSnippet() {
        pendingSnippet = nil
    }

    /// A session's display title, for the confirmation sheet.
    func sessionTitle(for id: Session.ID) -> String? {
        sessions.first { $0.id == id }?.displayTitle
    }

    /// Which session a snippet command is aimed at (mirrors `rootTarget`).
    private(set) var snippetTarget: Session.ID?
    /// Incremented when a command is ready to be typed.
    private(set) var snippetRequest = 0
    /// The command to run, built once so the terminal does not re-derive it.
    private(set) var snippetCommand = ""

    /// Called by the pane once it has handed the command over.
    func snippetHandled() {
        snippetCommand = ""
        snippetTarget = nil
    }

    // MARK: - Persistence

    func load() {
        do {
            if let stored = try store.load() {
                roots = stored
            } else {
                // First run: seed content and write it, so the tree is real data
                // the user can edit rather than a hard-coded placeholder.
                roots = ConnectionNode.sample
                try store.save(roots)
            }
        } catch {
            lastError = "Could not load connections: \(error)"
            roots = ConnectionNode.sample
        }
        // Passwords are NOT read here. Doing that at launch pulled every stored
        // secret out of the Keychain at once — one dialog per connection — which
        // is exactly the "10 prompts on launch" behaviour. They load lazily,
        // per node, the first time one is actually needed.
    }

    /// Saves the tree. Called by every mutation; cheap at this scale.
    ///
    /// `roots = roots` is deliberate: `ConnectionNode` is a plain reference type,
    /// so `@Observable` only tracks `AppModel`'s own stored properties. Mutating a
    /// nested node (`folder.name`, `folder.children`) changes no `AppModel`
    /// property and would otherwise leave the sidebar stale. Re-assigning `roots`
    /// fires the observation and re-renders the tree.
    private func persist() {
        roots = roots
        do {
            try store.save(roots)
            lastError = nil
        } catch {
            lastError = "Could not save connections: \(error)"
        }
    }

    /// Pulls a node's password out of the secret store into the in-memory node.
    /// Folders are included: a folder may hold a default password that its
    /// connections inherit.
    ///
    /// Called on demand (before a node is opened or edited), not for the whole
    /// tree at launch, so opening the app does not read every secret at once.
    private func hydratePassword(for node: ConnectionNode) {
        guard node.password.isEmpty else { return }
        node.password = (try? secrets.secret(for: node.id)) ?? ""
    }

    /// Resolves the credentials a connection needs, reading the node's own
    /// password and every ancestor folder's from the store (inheritance can pull
    /// a folder's default password).
    func hydrateCredentials(for id: ConnectionNode.ID) {
        guard let node = find(id) else { return }
        hydratePassword(for: node)
        var current = ConnectionNode.parentID(of: id, in: roots)
        while let parentID = current, let parent = find(parentID) {
            hydratePassword(for: parent)
            current = ConnectionNode.parentID(of: parentID, in: roots)
        }
    }

    // MARK: - Legacy keychain migration

    /// Moves passwords from the old per-node Keychain items into the encrypted
    /// store, once per install.
    ///
    /// Before v1.5.0 every node had its own Keychain item under service
    /// `com.emircankavas.kremote`; that scheme prompted once per connection after
    /// every app update. Those items are still on disk, so this reads each node's
    /// (and folder's) old item, writes it into `secrets.enc`, and deletes the old
    /// one. It runs at most once: a completion marker is stored, and it also skips
    /// any node the new store already covers.
    ///
    /// It is deliberately best-effort: a locked or denied Keychain must not stop
    /// the app from launching, so failures leave the marker unset and simply retry
    /// next time.
    private func migrateLegacyKeychainIfNeeded() {
        let defaultsKey = "legacyKeychainMigrated"
        guard !UserDefaults.standard.bool(forKey: defaultsKey) else { return }
        let legacy = LegacyKeychainSecretStore()
        guard legacy.hasAnyStoredSecret() else {
            // Nothing to move — mark done so a fresh install never probes again.
            UserDefaults.standard.set(true, forKey: defaultsKey)
            return
        }

        for node in ConnectionNode.allNodes(in: roots) {
            if ((try? secrets.secret(for: node.id)) ?? nil) != nil { continue }
            guard let secret = try? legacy.secret(for: node.id), !secret.isEmpty else {
                continue
            }
            do {
                try secrets.setSecret(secret, for: node.id)
                try? legacy.removeSecret(for: node.id)
            } catch {
                // Leave the old item in place; the marker stays unset and this
                // runs again next launch.
                lastError = "Could not migrate a saved password: \(error)"
                return
            }
        }
        UserDefaults.standard.set(true, forKey: defaultsKey)
    }

    // MARK: - Selection

    var selectedNode: ConnectionNode? {
        guard let selectedNodeID else { return nil }
        return ConnectionNode.find(selectedNodeID, in: roots)
    }

    /// Folder that should receive a newly created item.
    var selectedFolderID: ConnectionNode.ID? {
        guard let node = selectedNode else { return nil }
        return node.isFolder ? node.id : ConnectionNode.parentID(of: node.id, in: roots)
    }

    func find(_ id: ConnectionNode.ID) -> ConnectionNode? {
        ConnectionNode.find(id, in: roots)
    }

    /// Settings of a node with folders' values folded in.
    func effective(_ id: ConnectionNode.ID) -> EffectiveConnection? {
        ConnectionNode.effective(for: id, in: roots)
    }

    /// Search results for the sidebar filter; empty query means "not filtering".
    var searchQuery: String = ""
    var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var searchResults: [ConnectionNode] {
        ConnectionNode.search(searchQuery, in: roots)
    }

    // MARK: - Mutations

    func addFolder(inFolder folderID: ConnectionNode.ID?) {
        let folder = ConnectionNode(kind: .folder, name: "New Folder")
        insert(folder, into: folderID)
        selectedNodeID = folder.id
        persist()
    }

    func addConnection(inFolder folderID: ConnectionNode.ID?) {
        let connection = ConnectionNode(kind: .connection, name: "New Connection")
        insert(connection, into: folderID)
        selectedNodeID = connection.id
        editingNodeID = connection.id
        persist()
    }

    private func insert(_ node: ConnectionNode, into folderID: ConnectionNode.ID?) {
        guard let folderID, let folder = ConnectionNode.find(folderID, in: roots) else {
            roots.append(node)
            return
        }
        folder.children.append(node)
    }

    func rename(_ id: ConnectionNode.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let node = find(id) else { return }
        node.name = trimmed
        persist()
    }

    /// Moves a node into a folder (nil = root). No-op when the move is invalid.
    @discardableResult
    func move(_ id: ConnectionNode.ID, toFolder folderID: ConnectionNode.ID?) -> Bool {
        guard ConnectionNode.move(id, to: folderID, in: &roots) else { return false }
        persist()
        return true
    }

    func delete(_ id: ConnectionNode.ID) {
        guard let removed = ConnectionNode.remove(id, from: &roots) else { return }
        // Folders can hold a default password too, so clear secrets for every node.
        for node in ConnectionNode.allNodes(in: [removed]) {
            try? secrets.removeSecret(for: node.id)
        }
        if selectedNodeID == id { selectedNodeID = nil }
        sessions.removeAll { $0.nodeID == id }
        persist()
    }

    // MARK: - Editing

    func draft(for id: ConnectionNode.ID) -> ConnectionDraft? {
        // The editor shows the stored password, so load it (and inherited
        // folder defaults) for this node on demand.
        hydrateCredentials(for: id)
        return find(id).map(ConnectionDraft.init(from:))
    }

    /// Applies an edited draft back to the tree and the Keychain.
    func apply(_ draft: ConnectionDraft) {
        guard let node = find(draft.id) else { return }
        node.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        node.host = draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
        node.port = draft.port
        node.username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
        node.protocolName = draft.protocolName.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        node.identityFile = draft.identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        node.remoteCommand = draft.remoteCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        node.usesSudo = draft.usesSudo
        node.rdp = draft.rdp.isEmpty ? nil : draft.rdp
        node.password = draft.password

        do {
            try secrets.setSecret(draft.password, for: node.id)
            lastError = nil
        } catch {
            lastError = "Could not save password: \(error)"
        }

        // Keep a tab's title in sync with a rename.
        for index in sessions.indices where sessions[index].nodeID == node.id {
            sessions[index].title = node.name
        }
        persist()
    }

    // MARK: - Import (mRemoteNG confCons.xml)

    /// Set true to present the file picker.
    var isImportingConfCons = false
    /// Set when a file needs a master passphrase the default doesn't open.
    var pendingImportURL: URL?
    /// Human-readable result of the last import, shown as a notice.
    var importSummary: String?

    func importConfCons(from url: URL) {
        do {
            try performImport(from: url, passphrase: nil)
        } catch ConfConsImporter.ImportError.wrongPassphrase {
            // Needs a user master passphrase — the UI prompts, then calls the overload.
            pendingImportURL = url
        } catch {
            lastError = "Import failed: \(error)"
        }
    }

    func importConfCons(from url: URL, passphrase: String) {
        do {
            try performImport(from: url, passphrase: passphrase)
        } catch {
            lastError = "Import failed: \(error)"
        }
    }

    private func performImport(from url: URL, passphrase: String?) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        let result = try ConfConsImporter.importTree(from: data, passphrase: passphrase)

        // Imported passwords go straight into the Keychain under their node ids.
        for (id, secret) in result.passwords {
            try? secrets.setSecret(secret, for: id)
        }

        roots.append(contentsOf: result.roots)
        persist()

        let count = ConnectionNode.allNodes(in: result.roots).count
        let version = result.version.map { " (mRemoteNG schema \($0))" } ?? ""
        importSummary = "Imported \(count) item\(count == 1 ? "" : "s")\(version)."
    }

    // MARK: - Sessions

    /// Whether the detail area shows one session or a 2–4 pane split.
    var splitMode = false
    /// The visible panes (nil = empty). Length is 1 (normal) or 2–4 (split).
    private(set) var tiles: [Session.ID?] = [nil]
    /// Which pane has keyboard focus in split mode.
    var focusedTile = 0

    var paneLayout: PaneLayout {
        PaneLayout(count: splitMode ? tiles.count : 1)
    }

    /// Turns split mode on with `count` panes (clamped 2…4) or off.
    func setSplit(_ split: Bool, panes: Int? = nil) {
        if split {
            let target = min(max(panes ?? max(2, tiles.count), 2), PaneLayout.maximum)
            if tiles.count != target {
                tiles = PaneTiling.reconcile(
                    existing: tiles,
                    sessionIDs: sessions.map(\.id),
                    paneCount: target
                )
            }
            // Always show the active tab somewhere.
            if let active = activeSessionID, PaneTiling.tile(of: active, in: tiles) == nil {
                PaneTiling.place(session: active, in: &tiles, focusedTile: focusedTile)
            }
            splitMode = true
        } else {
            splitMode = false
            if let active = activeSessionID {
                tiles = [active]
            } else {
                tiles = [nil]
            }
            focusedTile = 0
        }
        reconcileTiles()
    }

    /// Changes the pane count while staying in split mode.
    func setPaneCount(_ count: Int) {
        guard splitMode else { return }
        let clamped = min(max(count, 1), PaneLayout.maximum)
        if clamped <= 1 { setSplit(false); return }
        tiles = PaneTiling.reconcile(existing: tiles, sessionIDs: sessions.map(\.id), paneCount: clamped)
        // The focused tile may no longer exist after trimming.
        focusedTile = min(focusedTile, tiles.count - 1)
        reconcileTiles()
    }

    /// Assigns `session` to the focused tile (used when switching a pane).
    func assign(_ session: Session.ID, toTile index: Int) {
        guard tiles.indices.contains(index) else { return }
        tiles[index] = session
        reconcileTiles()
    }

    func focusTile(_ index: Int) {
        guard tiles.indices.contains(index) else { return }
        focusedTile = index
        if let session = tiles[index] { activeSessionID = session }
    }

    /// Which pane currently shows `session`, if any.
    func tileIndex(of session: Session.ID) -> Int? {
        tiles.firstIndex { $0 == session }
    }

    /// Tabbing to a session: make it the active tab, and in split mode bring its
    /// pane into focus.
    func activateTab(_ id: Session.ID) {
        activeSessionID = id
        if splitMode, let index = tileIndex(of: id) { focusedTile = index }
    }

    /// A pane was clicked (or its terminal took focus): focus that session.
    func focus(_ id: Session.ID) {
        activeSessionID = id
        if splitMode, let index = tileIndex(of: id) { focusedTile = index }
    }

    /// Changes what the pane currently showing `existing` displays.
    func assign(_ newSession: Session.ID, toTileShowing existing: Session.ID) {
        if splitMode, let index = tileIndex(of: existing) {
            tiles[index] = newSession
            reconcileTiles()
        } else {
            activeSessionID = newSession
        }
    }

    /// Re-runs the tiling rules against the current session list. Called after any
    /// change that adds/removes sessions or changes the pane count.
    private func reconcileTiles() {
        let count = splitMode ? tiles.count : 1
        tiles = PaneTiling.reconcile(existing: tiles, sessionIDs: sessions.map(\.id), paneCount: count)
        if tiles.isEmpty { tiles = [nil] }
        focusedTile = tiles.isEmpty ? 0 : min(max(focusedTile, 0), tiles.count - 1)
    }

    /// Opens a session for a connection leaf. When `newTab` is false and the
    /// connection already has a tab, that tab is focused instead.
    func open(_ node: ConnectionNode, newTab: Bool = false) {
        guard !node.isFolder else { return }
        // Read this connection's credentials (and its folders') from the store
        // now, rather than at launch.
        hydrateCredentials(for: node.id)
        if !newTab, let existing = sessions.first(where: { $0.nodeID == node.id }) {
            activeSessionID = existing.id
            focusTiledSession(existing.id)
            return
        }
        let session = Session(nodeID: node.id, title: node.name)
        sessions.append(session)
        activeSessionID = session.id
        if splitMode {
            PaneTiling.place(session: session.id, in: &tiles, focusedTile: focusedTile)
            focusedTile = PaneTiling.tile(of: session.id, in: tiles) ?? focusedTile
        } else {
            tiles = [session.id]
        }
    }

    /// Points split focus at the tile showing `session`, if it is visible.
    private func focusTiledSession(_ session: Session.ID) {
        if splitMode, let index = PaneTiling.tile(of: session, in: tiles) {
            focusedTile = index
        }
    }

    /// Tears down and restarts the ssh process for a session.
    func reconnect(_ id: Session.ID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].generation += 1
        sessions[index].remoteTitle = nil
    }

    /// Current generation of a session, used to ignore state callbacks that
    /// arrive from a terminal view that has already been torn down.
    func currentGeneration(of id: Session.ID) -> Int? {
        sessions.first { $0.id == id }?.generation
    }

    /// The label a tab shows: the connection's name, and — only when the same
    /// connection is open more than once — a trailing "1", "2", … so two tabs to
    /// the same host can be told apart. A lone tab keeps a clean name.
    func tabLabel(for id: Session.ID) -> String {
        guard let session = sessions.first(where: { $0.id == id }) else { return "" }
        let sameConnection = sessions.filter { $0.nodeID == session.nodeID }
        guard sameConnection.count > 1,
              let index = sameConnection.firstIndex(where: { $0.id == id }) else {
            return session.title
        }
        return "\(session.title) \(index + 1)"
    }

    /// Applies a title pushed by the remote shell (OSC 0/2).
    func updateTitle(_ id: Session.ID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].remoteTitle = trimmed
    }

    func closeSession(_ id: Session.ID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let wasActiveTile = splitMode ? tiles.indices.contains(focusedTile) && tiles[focusedTile] == id : true
        sessions.remove(at: index)
        if activeSessionID == id {
            let next = min(index, sessions.count - 1)
            activeSessionID = sessions.isEmpty ? nil : sessions[next].id
        }
        reconcileTiles()
        // If the closed session was the focused pane, focus whatever took its place.
        if wasActiveTile, let active = activeSessionID, splitMode {
            focusedTile = PaneTiling.tile(of: active, in: tiles) ?? focusedTile
        }
    }

    /// Answers an outstanding RDP credential request. The C layer blocks the
    /// session thread until this (or `cancelRDPCredentials`) is called.
    func supplyRDPCredentials(username: String, domain: String, password: String) {
        let resolvedUser = username.isEmpty ? (pendingRDPLogin?.username ?? "") : username
        let resolvedDomain = domain.isEmpty ? (pendingRDPLogin?.domain ?? "") : domain
        pendingRDPLogin = nil
        rdpCredentialAnswer?(
            .supply(username: resolvedUser, domain: resolvedDomain, password: password)
        )
        rdpCredentialAnswer = nil
    }

    /// Abandons the credential request; the session then fails with the server's
    /// reason rather than hanging.
    func cancelRDPCredentials() {
        pendingRDPLogin = nil
        rdpCredentialAnswer?(.cancel)
        rdpCredentialAnswer = nil
    }

    var activeSession: Session? {
        guard let activeSessionID else { return nil }
        return sessions.first { $0.id == activeSessionID }
    }

    // MARK: - SFTP

    /// Open SFTP windows, one per connection. Kept on the model so that asking
    /// for the same connection twice raises the existing window instead of
    /// opening a second browser on the same server.
    private(set) var sftpSessions: [SFTPSession] = []

    /// The session for a connection, opening one if there is none yet.
    ///
    /// Works with no terminal open — the browser makes its own `ssh` connection,
    /// so it does not depend on a session having been started.
    func openSFTP(for nodeID: ConnectionNode.ID) -> SFTPSession? {
        if let existing = sftpSession(for: nodeID) { return existing }
        guard let node = find(nodeID), !node.isFolder else { return nil }
        hydrateCredentials(for: nodeID)
        guard let effective = effective(nodeID), !effective.host.isEmpty else {
            lastError = "This connection has no host set."
            return nil
        }
        // One provider for the whole session: the SFTP retry and the elevated
        // shell (Compress and Download) must agree on whether sudo is available.
        let sudoTarget = SudoTarget(
            nodeID: nodeID,
            host: effective.host,
            port: effective.port,
            username: effective.username,
            identityFile: effective.identityFile,
            usesSudo: node.usesSudo
        )
        let provider = SudoElevationProvider(target: sudoTarget, secretStore: self.secrets)

        // The builder is captured, not the client: Retry after a lost connection
        // needs a brand-new ssh process, which is what this closure makes.
        // Only ever invoked from the main actor (openSFTP / reconnect), so it is
        // not @Sendable and may read the node and the secret store.
        let makeClient: () -> SFTPClient = {
            let transport = ProcessSFTPTransport(
                host: effective.host,
                port: effective.port,
                username: effective.username,
                identityFile: effective.identityFile,
                // Password auth needs the stored secret: there is no terminal on
                // this connection, so ssh would otherwise fall back to a missing
                // ssh-askpass and fail before the protocol starts.
                password: effective.password,
                // Timeouts belong to ssh: a blocked pipe read cannot be cancelled
                // from Swift, so without these a black-holed host would leave the
                // window on "Connecting…" forever. ConnectTimeout bounds the
                // handshake; ServerAlive* ends a session that stops answering.
                extraOptions: [
                    "-o", "ConnectTimeout=20",
                    "-o", "ServerAliveInterval=15",
                    "-o", "ServerAliveCountMax=3",
                ]
            )
            // Elevation is per operation and only wired when the node opted in: the
            // provider returns nil without the flag or without a usable password, and
            // the base channel keeps serving everything the login user may do.
            return SFTPClient(transport: transport, elevation: provider)
        }
        let user = effective.username.isEmpty ? "" : "\(effective.username)@"
        let session = SFTPSession(
            nodeID: nodeID,
            title: node.name,
            target: "sftp://\(user)\(effective.host):\(effective.port)",
            connection: SFTPSession.Connection(
                host: effective.host,
                port: effective.port,
                username: effective.username,
                identityFile: effective.identityFile,
                password: effective.password
            ),
            elevation: provider,
            makeClient: makeClient
        )
        sftpSessions.append(session)
        return session
    }

    /// Installed by the main window: turns "show SFTP for this node" into
    /// `openWindow(id:value:)`, which raises an existing window for the same
    /// node instead of stacking a second browser on the same server.
    ///
    /// The menu, the sidebar and the session toolbar all come through here, so
    /// there is exactly one place that knows how a window is opened.
    var openSFTPWindow: ((ConnectionNode.ID) -> Void)?

    /// Opens the browser for a connection, or raises the one already open.
    func showSFTP(for nodeID: ConnectionNode.ID) {
        guard let session = openSFTP(for: nodeID) else { return }
        openSFTPWindow?(session.nodeID)
    }

    /// Called by the window when it closes; drops the client with it.
    func closeSFTP(_ id: SFTPSession.ID) {
        guard let session = sftpSessions.first(where: { $0.id == id }) else { return }
        session.disconnect()
        sftpSessions.removeAll { $0.id == id }
    }

    /// The session open for a node, if any.
    func sftpSession(for nodeID: ConnectionNode.ID) -> SFTPSession? {
        sftpSessions.first { $0.nodeID == nodeID }
    }

    // MARK: - Elevation

    /// Incremented each time the user asks to become root; the targeted terminal
    /// watches this and writes the sudo command.
    private(set) var rootRequest = 0
    /// Which session the last root request was aimed at. Set only by
    /// `requestRoot` — never by focus changes — so merely clicking around panes
    /// cannot look like a new request.
    private(set) var rootTarget: Session.ID?

    func requestRoot() {
        guard let session = focusedSession else { return }
        rootTarget = session.id
        rootRequest += 1
    }

    /// The session shown in the focused pane (where `sudo -i` runs). Falls back to
    /// the active session, so it also works in single-pane mode.
    var focusedSession: Session? {
        if splitMode, tiles.indices.contains(focusedTile), let id = tiles[focusedTile] {
            return sessions.first { $0.id == id }
        }
        return activeSession
    }
}
