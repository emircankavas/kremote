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

    private let store: NodeStore
    private let secrets: SecretStore

    init(store: NodeStore = .defaultStore(), secrets: SecretStore? = nil) {
        self.store = store
        self.secrets = secrets ?? KeychainSecretStore()
        load()
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
            hydratePasswords()
        } catch {
            lastError = "Could not load connections: \(error)"
            roots = ConnectionNode.sample
            hydratePasswords()
        }
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

    /// Pulls each leaf's password out of the secret store into the in-memory node.
    private func hydratePasswords() {
        for node in ConnectionNode.allNodes(in: roots) where !node.isFolder {
            node.password = (try? secrets.secret(for: node.id)) ?? ""
        }
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
        for node in ConnectionNode.allNodes(in: [removed]) where !node.isFolder {
            try? secrets.removeSecret(for: node.id)
        }
        if selectedNodeID == id { selectedNodeID = nil }
        sessions.removeAll { $0.nodeID == id }
        persist()
    }

    // MARK: - Editing

    func draft(for id: ConnectionNode.ID) -> ConnectionDraft? {
        find(id).map(ConnectionDraft.init(from:))
    }

    /// Applies an edited draft back to the tree and the Keychain.
    func apply(_ draft: ConnectionDraft) {
        guard let node = find(draft.id) else { return }
        node.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        node.host = draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
        node.port = draft.port
        node.username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
        node.protocolName = draft.protocolName.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
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

    /// Opens a session for a connection leaf. When `newTab` is false and the
    /// connection already has a tab, that tab is focused instead.
    func open(_ node: ConnectionNode, newTab: Bool = false) {
        guard !node.isFolder else { return }
        if !newTab, let existing = sessions.first(where: { $0.nodeID == node.id }) {
            activeSessionID = existing.id
            return
        }
        let session = Session(nodeID: node.id, title: node.name)
        sessions.append(session)
        activeSessionID = session.id
    }

    /// Tears down and restarts the ssh process for a session.
    func reconnect(_ id: Session.ID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].generation += 1
        sessions[index].remoteTitle = nil
    }

    /// Applies a title pushed by the remote shell (OSC 0/2).
    func updateTitle(_ id: Session.ID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].remoteTitle = trimmed
    }

    func closeSession(_ id: Session.ID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions.remove(at: index)
        if activeSessionID == id {
            let next = min(index, sessions.count - 1)
            activeSessionID = sessions.isEmpty ? nil : sessions[next].id
        }
    }

    var activeSession: Session? {
        guard let activeSessionID else { return nil }
        return sessions.first { $0.id == activeSessionID }
    }
}
