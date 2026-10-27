import SwiftUI
import UniformTypeIdentifiers
import KRemoteCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    @State private var pendingPassphrase = ""
    /// Remembered so the sheet's `onDismiss` knows which node was being edited: by then
    /// `editingNodeID` is already nil.
    @State private var lastEditorNodeID: ConnectionNode.ID?
    @State private var showImportNotice = false

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 460)
        } detail: {
            // Tabs in their own row, full width, under the title bar. In the
            // toolbar they shared the strip with the window controls and the
            // session buttons, which capped them at ~720 pt and hid the sixth
            // session behind a horizontal scroll.
            VStack(spacing: 0) {
                if !model.sessions.isEmpty {
                    TabStrip()
                        .frame(height: 34)
                    Divider()
                }
                DetailView()
            }
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
            ToolbarItemGroup(placement: .primaryAction) {
                SessionToolbarItems()
            }
        }
        .sheet(item: $model.editingNodeID, onDismiss: {
            // Escape and the sheet's own close path skip the Cancel button, so the
            // discard also runs here. It is idempotent: the button removes the id first,
            // and this finds nothing left to remove.
            if let id = lastEditorNodeID { model.discardIfUnsaved(id) }
            lastEditorNodeID = nil
        }) { id in
            ConnectionEditorView(nodeID: id) { model.editingNodeID = nil }
                .onAppear { lastEditorNodeID = id }
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
/// The multi-execution toggle.
///
/// Its own view because it has three visual states — off, on, and unavailable — and the
/// third one is the reason it exists: a control that paints its own colours does not dim
/// itself when disabled, so it has to be done here.
private struct BroadcastButton: View {
    let isOn: Bool
    let isAvailable: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "keyboard.badge.ellipsis")
                .foregroundStyle(glyphColour)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isOn && isAvailable ? Color.orange : Color.clear)
                )
        }
        .help(helpText)
        .accessibilityLabel("Broadcast input to all sessions")
        .accessibilityValue(isOn ? "on" : "off")
        .disabled(!isAvailable)
    }

    private var glyphColour: Color {
        if !isAvailable { return .secondary.opacity(0.4) }
        return isOn ? .white : .primary
    }

    private var helpText: String {
        if !isAvailable {
            return "Open two or more SSH sessions to send input to all of them"
        }
        return isOn
            ? "Every keystroke is going to all SSH sessions — click to stop"
            : "Send every keystroke to all SSH sessions"
    }
}

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
        // An explicit colour overrides the dimming `.disabled` normally applies, so a
        // `Color.primary` glyph stayed fully opaque and looked clickable with no sessions
        // open — unlike every neighbouring icon. `isEnabled` is read and the tint chosen
        // by hand, which is the only way to dim a view that already paints itself.
        BroadcastButton(isOn: model.isBroadcasting, isAvailable: model.broadcastTargets.count >= 2) {
            model.isBroadcasting.toggle()
        }

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
