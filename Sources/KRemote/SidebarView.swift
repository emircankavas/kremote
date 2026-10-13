import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

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
        .onDeleteCommand { deleteSelection() }
    }

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
        Button("Rename…") { renameAlertTarget = node.id }
        Button("Delete", role: .destructive) { model.delete(node.id) }
    }

    @State private var renameAlertTarget: ConnectionNode.ID?

    private func deleteSelection() {
        if let id = model.selectedNodeID { model.delete(id) }
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
