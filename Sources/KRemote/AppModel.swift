import Foundation
import Observation

/// An open remote session. Faz 0 only records that a tab exists; Faz 3 attaches
/// a live SSH transport + terminal view to it.
struct Session: Identifiable, Hashable {
    let id = UUID()
    let nodeID: ConnectionNode.ID
    var title: String

    static func == (lhs: Session, rhs: Session) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor
@Observable
final class AppModel {
    /// Root of the connection tree.
    var roots: [ConnectionNode] = ConnectionNode.sample

    /// Currently highlighted row in the sidebar. Drives where new items go.
    var selectedNodeID: ConnectionNode.ID?

    /// Open session tabs, in order.
    var sessions: [Session] = []
    var activeSessionID: Session.ID?

    // MARK: - Selection

    var selectedNode: ConnectionNode? {
        guard let selectedNodeID else { return nil }
        return find(selectedNodeID)
    }

    /// Folder that should receive a newly created item.
    var selectedFolderID: ConnectionNode.ID? {
        guard let node = selectedNode else { return nil }
        return node.isFolder ? node.id : parentID(of: node.id)
    }

    func find(_ id: ConnectionNode.ID) -> ConnectionNode? {
        Self.find(id, in: roots)
    }

    private static func find(_ id: ConnectionNode.ID, in nodes: [ConnectionNode]) -> ConnectionNode? {
        for node in nodes {
            if node.id == id { return node }
            if let hit = find(id, in: node.children) { return hit }
        }
        return nil
    }

    private func parentID(of id: ConnectionNode.ID) -> ConnectionNode.ID? {
        Self.parentID(of: id, in: roots, parent: nil)
    }

    private static func parentID(
        of id: ConnectionNode.ID,
        in nodes: [ConnectionNode],
        parent: ConnectionNode.ID?
    ) -> ConnectionNode.ID? {
        for node in nodes {
            if node.id == id { return parent }
            if let hit = parentID(of: id, in: node.children, parent: node.id) { return hit }
        }
        return nil
    }

    // MARK: - Mutations

    func addFolder(inFolder folderID: ConnectionNode.ID?) {
        let folder = ConnectionNode(kind: .folder, name: "New Folder")
        insert(folder, into: folderID)
        selectedNodeID = folder.id
    }

    func addConnection(inFolder folderID: ConnectionNode.ID?) {
        let connection = ConnectionNode(kind: .connection, name: "New Connection")
        insert(connection, into: folderID)
        selectedNodeID = connection.id
    }

    private func insert(_ node: ConnectionNode, into folderID: ConnectionNode.ID?) {
        guard let folderID, let folder = find(folderID) else {
            roots.append(node)
            return
        }
        folder.children.append(node)
    }

    func rename(_ id: ConnectionNode.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        find(id)?.name = trimmed
    }

    func delete(_ id: ConnectionNode.ID) {
        if Self.remove(id, from: &roots) {
            if selectedNodeID == id { selectedNodeID = nil }
            sessions.removeAll { $0.nodeID == id }
        }
    }

    @discardableResult
    private static func remove(_ id: ConnectionNode.ID, from nodes: inout [ConnectionNode]) -> Bool {
        if let index = nodes.firstIndex(where: { $0.id == id }) {
            nodes.remove(at: index)
            return true
        }
        for node in nodes {
            if remove(id, from: &node.children) { return true }
        }
        return false
    }

    // MARK: - Sessions

    /// Opens (or focuses) a session for a connection leaf.
    func open(_ node: ConnectionNode) {
        guard !node.isFolder else { return }
        // One tab per connection for now; Faz 4 adds "open in new tab".
        if let existing = sessions.first(where: { $0.nodeID == node.id }) {
            activeSessionID = existing.id
            return
        }
        let session = Session(nodeID: node.id, title: node.name)
        sessions.append(session)
        activeSessionID = session.id
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
