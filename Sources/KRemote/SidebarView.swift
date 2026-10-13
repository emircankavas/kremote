import SwiftUI
import KRemoteCore

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    @State private var renameTarget: ConnectionNode.ID?
    @State private var renameDraft: String = ""
    @State private var deleteTarget: ConnectionNode.ID?

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            searchField
            Divider()
            tree
        }
        .onDeleteCommand { deleteTarget = model.selectedNodeID }
        .alert("Rename", isPresented: renamePresented, presenting: renameTarget) { id in
            TextField("Name", text: $renameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { model.rename(id, to: renameDraft) }
        }
        .confirmationDialog(
            "Delete this item?",
            isPresented: deletePresented,
            presenting: deleteTarget
        ) { id in
            Button("Delete", role: .destructive) { model.delete(id) }
            Button("Cancel", role: .cancel) {}
        } message: { id in
            Text(deleteMessage(for: id))
        }
    }

    // MARK: - Search

    @ViewBuilder
    private var searchField: some View {
        @Bindable var model = model
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Search connections", text: $model.searchQuery)
                .textFieldStyle(.plain)
            if model.isSearching {
                Button {
                    model.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
    }

    // MARK: - Tree / results

    @ViewBuilder
    private var tree: some View {
        @Bindable var model = model

        if model.isSearching {
            let results = model.searchResults
            if results.isEmpty {
                Text("No matches")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selectedNodeID) {
                    ForEach(results) { node in
                        NodeRow(node: node, effective: model.effective(node.id), showsPath: true)
                            .tag(node.id)
                            .contextMenu { menu(for: node) }
                    }
                }
                .listStyle(.sidebar)
            }
        } else {
            List(selection: $model.selectedNodeID) {
                OutlineGroup(model.roots, children: \.childNodes) { node in
                    NodeRow(node: node, effective: model.effective(node.id))
                        .tag(node.id)
                        .contextMenu { menu(for: node) }
                        .draggable(node.id.uuidString) {
                            Label(node.name, systemImage: node.isFolder ? "folder" : "terminal")
                        }
                        .dropDestination(for: String.self) { items, _ in
                            drop(items, onto: node)
                        }
                }
            }
            .listStyle(.sidebar)
        }
    }

    /// Handles a drop of dragged node ids onto `target` (a folder nests them, a
    /// connection sends them to that connection's parent folder).
    private func drop(_ items: [String], onto target: ConnectionNode) -> Bool {
        let destinationFolder = target.isFolder
            ? target.id
            : ConnectionNode.parentID(of: target.id, in: model.roots)
        var movedAny = false
        for uuidString in items {
            guard let uuid = UUID(uuidString: uuidString) else { continue }
            if model.move(uuid, toFolder: destinationFolder) { movedAny = true }
        }
        return movedAny
    }

    // MARK: - Alerts

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    private func deleteMessage(for id: ConnectionNode.ID) -> String {
        guard let node = model.find(id) else { return "" }
        if node.isFolder, !node.children.isEmpty {
            return "\"\(node.name)\" and its \(node.children.count) item(s) will be removed."
        }
        return "\"\(node.name)\" will be removed."
    }

    private func beginRename(_ node: ConnectionNode) {
        renameDraft = node.name
        renameTarget = node.id
    }

    // MARK: - Context menu

    @ViewBuilder
    private func menu(for node: ConnectionNode) -> some View {
        if node.isFolder {
            Button("New Connection") { model.addConnection(inFolder: node.id) }
            Button("New Folder") { model.addFolder(inFolder: node.id) }
            Divider()
        } else {
            Button("Open") { model.open(node) }
            Button("Open in New Tab") { model.open(node, newTab: true) }
            Divider()
        }
        Button("Edit…") { model.editingNodeID = node.id }
        Button("Rename…") { beginRename(node) }
        Button("Delete", role: .destructive) { deleteTarget = node.id }
    }
}

private struct NodeRow: View {
    @Environment(AppModel.self) private var model
    let node: ConnectionNode
    let effective: EffectiveConnection?
    var showsPath: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: node.isFolder ? "folder" : "terminal")
                .foregroundStyle(node.isFolder ? Color.accentColor : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name)
                    .lineLimit(1)
                if !node.isFolder, let subtitle = subtitleText {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.open(node) }
    }

    /// On search results the folder path is shown first (so a deep host is
    /// locatable); otherwise just the resolved connection summary.
    private var subtitleText: String? {
        let connection = effective?.summary
        if showsPath, let path = pathText {
            if let connection, connection != "not configured" { return "\(path) · \(connection)" }
            return path
        }
        return connection
    }

    private var pathText: String? {
        guard showsPath else { return nil }
        var parts: [String] = []
        var current = ConnectionNode.parentID(of: node.id, in: model.roots)
        while let id = current, let parent = model.find(id) {
            parts.insert(parent.name, at: 0)
            current = ConnectionNode.parentID(of: id, in: model.roots)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ▸ ")
    }
}
