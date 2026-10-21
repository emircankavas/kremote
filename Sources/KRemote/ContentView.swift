import SwiftUI
import UniformTypeIdentifiers
import KRemoteCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    @State private var pendingPassphrase = ""
    @State private var showImportNotice = false

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 460)
        } detail: {
            DetailView()
        }
        .navigationTitle("KRemote")
        // One place turns "show SFTP for a node" into a window. `openWindow` with
        // a value raises the window already bound to that value, which is what
        // makes a second invoke focus instead of duplicate.
        .task {
            model.openSFTPWindow = { nodeID in
                openWindow(id: "sftp", value: nodeID)
            }
        }
        .toolbar {
            // Tabs centred in the window's title bar — the layout that worked.
            ToolbarItem(placement: .principal) {
                if !model.sessions.isEmpty {
                    TabStrip()
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                SessionToolbarItems()
            }
        }
        .sheet(item: $model.editingNodeID) { id in
            ConnectionEditorView(nodeID: id) { model.editingNodeID = nil }
        }
        // Confirmation comes before execution: a snippet is code, and the menu is one
        // click from a production server.
        .sheet(item: $model.pendingSnippet) { pending in
            SnippetConfirmSheet(pending: pending)
        }
        .sheet(isPresented: $model.isCreatingSnippet, onDismiss: {
            // A new snippet closes the sheet directly from the editor, so nothing is
            // left to do here beyond keeping the flag honest.
        }) {
            SnippetEditorView(snippetID: nil) { model.isCreatingSnippet = false }
        }
        .sheet(item: $model.editingSnippetID) { id in
            SnippetEditorView(snippetID: id) { model.editingSnippetID = nil }
        }
        .fileImporter(
            isPresented: $model.isImportingConfCons,
            allowedContentTypes: [.xml],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { model.importConfCons(from: url) }
            case .failure(let error):
                model.lastError = "Could not open file: \(error.localizedDescription)"
            }
        }
        .alert("Master passphrase required", isPresented: passphrasePresented) {
            SecureField("Passphrase", text: $pendingPassphrase)
            Button("Cancel", role: .cancel) {
                pendingPassphrase = ""
                model.pendingImportURL = nil
            }
            Button("Import") {
                if let url = model.pendingImportURL {
                    model.importConfCons(from: url, passphrase: pendingPassphrase)
                }
                pendingPassphrase = ""
                model.pendingImportURL = nil
            }
        } message: {
            Text("This confCons.xml was saved with a custom master password.")
        }
        .alert("Import complete", isPresented: $showImportNotice) {
            Button("OK", role: .cancel) { model.importSummary = nil }
        } message: {
            Text(model.importSummary ?? "")
        }
        .onChange(of: model.importSummary) { _, newValue in
            showImportNotice = newValue != nil
        }
        .alert("KRemote", isPresented: errorPresented) {
            Button("OK", role: .cancel) { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })
    }

    private var passphrasePresented: Binding<Bool> {
        Binding(get: { model.pendingImportURL != nil }, set: { if !$0 { model.pendingImportURL = nil } })
    }
}

/// Lets `sheet(item:)` accept a plain `UUID` node id.
extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}

/// The SFTP, `#` (become root) and split-view controls, shown in the window title bar.
struct SessionToolbarItems: View {
    @Environment(AppModel.self) private var model

    /// SFTP for the session in focus; falls back to the sidebar selection so the
    /// button also works with no terminal open.
    private var sftpTarget: ConnectionNode.ID? {
        guard let nodeID = model.focusedSession?.nodeID ?? model.selectedNodeID else { return nil }
        guard let node = model.find(nodeID), node.supportsSSH else { return nil }
        return nodeID
    }

    var body: some View {
        Button {
            guard let nodeID = sftpTarget else { return }
            model.showSFTP(for: nodeID)
        } label: {
            Image(systemName: "folder.badge.gearshape")
        }
        .help("Browse this server's files over SFTP (⇧⌘S)")
        .accessibilityLabel("Browse files over SFTP")
        .disabled(sftpTarget == nil)

        SnippetMenuButton()

        // Multi-execution: mirror every keystroke into the other SSH sessions.
        //
        // Drawn by hand rather than with `.toggleStyle(.button)`: the system's button
        // toggle style did not show a pressed state in this toolbar, and the previous
        // version swapped between two SF Symbols that do not exist on this OS — it
        // rendered as an empty circle with no colour change at all. A filled background
        // when on is the one thing a user cannot misread.
        Button {
            model.isBroadcasting.toggle()
        } label: {
            Image(systemName: "keyboard.badge.ellipsis")
                .foregroundStyle(model.isBroadcasting ? Color.white : Color.primary)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(model.isBroadcasting ? Color.orange : Color.clear)
                )
        }
        // No `.plain`: that strips the toolbar's own button framing, which is what made
        // this item look like it belonged to a different control group than its
        // neighbours. The tint is supplied by the background instead.
        .help(model.isBroadcasting
              ? "Every keystroke is going to all SSH sessions — click to stop"
              : "Send every keystroke to all SSH sessions")
        .accessibilityLabel("Broadcast input to all sessions")
        .accessibilityValue(model.isBroadcasting ? "on" : "off")
        .disabled(model.broadcastTargets.count < 2)

        Button {
            model.requestRoot()
        } label: {
            Image(systemName: "number")
        }
        .help("Become root on the focused session (runs sudo -i)")
        .accessibilityLabel("Become root")
        .disabled(model.focusedSession == nil)

        Button {
            model.setSplit(!model.splitMode, panes: model.splitMode ? nil : 2)
        } label: {
            Image(systemName: model.splitMode ? "square.split.2x1.fill" : "square.split.2x1")
        }
        .help(model.splitMode ? "Exit split view" : "Split into two panes")
        .disabled(model.sessions.count < 2 && !model.splitMode)

        if model.splitMode {
            ForEach(2...PaneLayout.maximum, id: \.self) { count in
                Button("\(count)") { model.setPaneCount(count) }
                    .help("\(count) panes")
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(AppModel())
        .frame(width: 1000, height: 640)
}
