import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    @State private var renameTarget: ConnectionNode.ID?
    @State private var renameDraft: String = ""
    @State private var deleteTarget: ConnectionNode.ID?

    var body: some View {
        @Bindable var model = model

        List(selection: $model.selectedNodeID) {
            OutlineGroup(model.roots, children: \.childNodes) { node in
                NodeRow(node: node)
                    .tag(node.id)
                    .contextMenu { menu(for: node) }
            }
        }
        .listStyle(.sidebar)
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
            Divider()
        }
        Button("Rename…") { beginRename(node) }
        Button("Delete", role: .destructive) { deleteTarget = node.id }
    }
}

private struct NodeRow: View {
    @Environment(AppModel.self) private var model
    let node: ConnectionNode

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: node.isFolder ? "folder" : "terminal")
                .foregroundStyle(node.isFolder ? Color.accentColor : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name)
                    .lineLimit(1)
                if !node.isFolder {
                    Text(node.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.open(node) }
    }
}
