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

    /// "Connect to <what you typed>", with the protocol chosen from its own menu.
    ///
    /// A row rather than a button so it sits in the results list where the eye already
    /// is, and a menu rather than a second dialog so the choice of protocol is one click
    /// away from the decision to connect.
    @ViewBuilder
    private func adHocRow(_ target: AdHocTarget) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Connect to “\(target.displayLabel)”")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(target.username.isEmpty
                     ? "Not in the tree"
                     : "as \(target.username)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Connect with SSH") { model.connectAdHoc(target, protocol: .ssh) }
                Button("Connect with RDP") { model.connectAdHoc(target, protocol: .rdp) }
                Divider()
                Button("Add server…") { model.addServer(target, protocol: .ssh) }
            } label: {
                // Bordered and tinted rather than a bare glyph: an untinted chevron in a
                // sidebar row is nearly invisible on a dark background, which is exactly
                // how this was reported.
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.accentColor.opacity(0.15))
                    )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Connect, or add this server")
        }
        .contentShape(Rectangle())
        // The whole row opens SSH: it is the common case, and requiring a menu for the
        // default would be a click for nothing. The chevron picks the other protocol.
        .onTapGesture { model.connectAdHoc(target, protocol: .ssh) }
    }

    /// "Add … as a server", as its own row.
    ///
    /// The same action sits in the connect row's menu, but a menu is where features go to
    /// be undiscovered: saving a host is the thing a user wants when they type an address
    /// they intend to keep, so it earns a visible row of its own.
    @ViewBuilder
    private func addServerRow(_ target: AdHocTarget) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.rectangle.on.folder")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Add “\(target.displayLabel)” as a server")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Save it to the sidebar")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { model.addServer(target, protocol: .ssh) }
    }

    // MARK: - Tree / results

    @ViewBuilder
    private var tree: some View {
        @Bindable var model = model

        if model.isSearching {
            let results = model.searchResults
            // What was typed, if it could be a host **and** the tree does not already
            // have it. Offering an ad-hoc connection to an address that is saved under a
            // name would throw away that name, its folder and the credentials inherited
            // from it — for a host the app already knows. The saved entry is the answer;
            // the ad-hoc row is only for addresses that are genuinely absent.
            let adHoc = AdHocTarget.parse(model.searchQuery).flatMap { target in
                AdHocTarget.existingMatches(for: target, in: model.roots).isEmpty ? target : nil
            }

            if results.isEmpty, adHoc == nil {
                Text("No matches")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selectedNodeID) {
                    ForEach(results) { node in
                        NodeRow(node: node, showsPath: true)
                            .tag(node.id)
                            .contextMenu { menu(for: node) }
                    }
                    if let adHoc {
                        adHocRow(adHoc)
                        addServerRow(adHoc)
                    }
                }
                .listStyle(.sidebar)
            }
        } else {
            List(selection: $model.selectedNodeID) {
                OutlineGroup(model.roots, children: \.childNodes) { node in
                    NodeRow(node: node)
                        .tag(node.id)
                        .contextMenu { menu(for: node) }
                        // `.onDrag` with an explicit NSItemProvider, not
                        // `.draggable`: on a `List` row the Transferable variant
                        // never started a drag at all (the row answered with a
                        // plain text item that AppKit's text services claimed),
                        // and a private UTI is also what keeps a drop from
                        // accepting text dragged in from another app.
                        .onDrag {
                            NodeDrag.begin([node.id])
                            return NodeDragPayload.provider(for: [node.id])
                        } preview: {
                            Label(node.name, systemImage: node.isFolder ? "folder" : "terminal")
                                .padding(4)
                        }
                        .onDrop(
                            of: [.kremoteNode],
                            delegate: NodeDropDelegate(
                                target: node,
                                // A connection is a legal drop target: it means
                                // "put this beside that connection", i.e. into its
                                // folder — the same rule as mRemoteNG.
                                destination: node.isFolder
                                    ? node.id
                                    : ConnectionNode.parentID(of: node.id, in: model.roots),
                                model: model,
                                drop: drop
                            )
                        )
                }
            }
            .listStyle(.sidebar)
            // Dropping anywhere that is not a row moves to the top level: without
            // this there was no way to take an item back out of a folder with the
            // mouse, and the empty area below the tree is the natural target.
            .onDrop(
                of: [.kremoteNode],
                delegate: RootDropDelegate(model: model, drop: drop)
            )
            .overlay {
                if model.isRootDropTarget {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(2)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    /// Moves the dragged nodes into `destination` (nil = top level).
    ///
    /// Returns whether anything moved, so the drop delegate can tell AppKit the
    /// drop was accepted and play the snap-back animation when it was not. A
    /// refused move is reported: silently doing nothing is indistinguishable from
    /// a broken drag.
    @discardableResult
    private func drop(_ ids: [ConnectionNode.ID], into destination: ConnectionNode.ID?) -> Bool {
        var moved = false
        var refused = 0
        for id in ids {
            // A node into itself, or into its own descendant, is the one case the
            // tree rules refuse — say so rather than appearing to work.
            if id == destination || model.containsNode(destination, inside: id) {
                refused += 1
                continue
            }
            if model.move(id, toFolder: destination) { moved = true }
        }
        if moved { NodeDrag.finish() }
        if refused > 0 {
            model.lastError = "A folder cannot be moved into itself or one of its own subfolders."
        }
        return moved
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
            // Connect ▸ submenu: the keyboard-free way to reach a session, and
            // the only way to open SFTP without a terminal already running.
            Menu("Connect") {
                Button("Open Terminal") { model.open(node) }
                Button("Terminal in New Tab") { model.open(node, newTab: true) }
                Divider()
                Button("SFTP") { openSFTP(node) }
                    .disabled(!node.supportsSSH)
            }
            Button("Open") { model.open(node) }
            Button("Open in New Tab") { model.open(node, newTab: true) }
            Divider()
        }
        Divider()
        // Credentials are the thing people reach for the context menu for: copying a
        // login name or a password beats reading it out of the editor. Offered for
        // folders too, where the value is the group default the members inherit.
        Button("Copy Username") {
            copy(model.copyableUsername(for: node.id))
        }
        .disabled(model.copyableUsername(for: node.id) == nil)

        Button("Copy Password") {
            copy(model.copyablePassword(for: node.id))
        }
        .disabled(model.copyablePassword(for: node.id) == nil)

        Divider()
        Button("Edit…") { model.editingNodeID = node.id }
        Button("Rename…") { beginRename(node) }
        Button("Delete", role: .destructive) { deleteTarget = node.id }
    }

    /// Puts text on the general pasteboard.
    ///
    /// Nothing else happens: no history, no confirmation dialog. Copying a password to
    /// paste it into a login prompt is the whole point, and a dialog would make the
    /// obvious thing slower than selecting the text by hand.
    private func copy(_ text: String?) {
        guard let text, !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func openSFTP(_ node: ConnectionNode) {
        model.showSFTP(for: node.id)
    }
}

private struct NodeRow: View {
    @Environment(AppModel.self) private var model
    let node: ConnectionNode
    var showsPath: Bool = false

    var body: some View {
        // Resolve the effective settings *inside* the body rather than taking
        // them as an input. `ConnectionNode` is a reference type, so editing a
        // node mutates it in place: no observable property of `AppModel`
        // changes except `roots`, which `persist()` reassigns. Reading
        // `model.roots` (through `effective(_:)`) here is what subscribes this
        // row to that reassignment, so the subtitle refreshes as soon as an
        // edit is saved. With the value captured as a parameter the row read no
        // observable state, SwiftUI reused it, and the subtitle stayed stale
        // until the next launch.
        let effective = model.effective(node.id)

        HStack(spacing: 6) {
            // The icon says how this entry is reached: a folder, a shell, or a remote
            // desktop. One terminal glyph for every connection hides the distinction
            // that decides what double-clicking does.
            Image(systemName: rowSymbol)
                .foregroundStyle(node.isFolder ? Color.accentColor : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name)
                    .lineLimit(1)
                if !node.isFolder, let subtitle = subtitleText(effective) {
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

    /// The icon for this row.
    ///
    /// RDP gets its own glyph rather than a variant of the terminal one: the two open
    /// completely different windows, so telling them apart at a glance is the point.
    private var rowSymbol: String {
        if node.isFolder { return "folder" }
        return node.supportsRDP ? "display" : "terminal"
    }

    /// The address, first: it is what a connection *is*.
    ///
    /// This used to show the tree path on search results, which answered "where in the
    /// sidebar is this?" — a question nobody asks while searching for a host. The address
    /// is the thing being looked for, so it leads; the folder is still shown after it, so
    /// two entries with the same address in different folders stay distinguishable.
    private func subtitleText(_ effective: EffectiveConnection?) -> String? {
        guard let effective,
              let address = ConnectionSubtitle.address(
                host: effective.host,
                username: effective.username,
                port: effective.port,
                protocolName: effective.protocolName
              )
        else { return nil }
        return ConnectionSubtitle.address(address, path: showsPath ? (pathComponents ?? []) : [])
    }

    private var pathComponents: [String]? {
        var parts: [String] = []
        var current = ConnectionNode.parentID(of: node.id, in: model.roots)
        while let id = current, let parent = model.find(id) {
            parts.insert(parent.name, at: 0)
            current = ConnectionNode.parentID(of: id, in: model.roots)
        }
        return parts.isEmpty ? nil : parts
    }
}
