import SwiftUI
import UniformTypeIdentifiers
import KRemoteCore

struct ContentView: View {
    @Environment(AppModel.self) private var model

    @State private var pendingPassphrase = ""
    @State private var showImportNotice = false

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 460)
        } detail: {
            VStack(spacing: 0) {
                WindowHeader()
                Divider()
                DetailView()
            }
        }
        // The window title is drawn by `WindowHeader` inside the detail area, not
        // by the system toolbar. A `.navigation` item on a NavigationSplitView
        // lands in the *sidebar column's* title area, which put the tabs inside
        // that pill and exposed the system toolbar's own customisation menu on
        // right-click — neither of which is wanted here.
        .navigationTitle("")
        .sheet(item: $model.editingNodeID) { id in
            ConnectionEditorView(nodeID: id) { model.editingNodeID = nil }
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

/// The app's single header row: title, session tabs, and the session controls.
///
/// With `.windowStyle(.hiddenTitleBar)` there is no system bar, so this is the
/// only row above the sessions — it must lay out the whole thing, including the
/// inset that keeps it clear of the traffic-light buttons that float over its
/// leading edge.
struct WindowHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            // Clears the traffic lights (they hover over this row).
            Spacer().frame(width: 70)
            Text("KRemote")
                .font(.headline)
                .layoutPriority(1)
            if !model.sessions.isEmpty {
                TabStrip()
            }
            Spacer(minLength: 0)
            SessionToolbarItems()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// The `#` (become root) and split-view controls, shown in the window title bar.
struct SessionToolbarItems: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.requestRoot()
        } label: {
            Image(systemName: "number")
        }
        .help("Become root on the focused session (runs sudo -i)")
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
