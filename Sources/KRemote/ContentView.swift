import SwiftUI
import UniformTypeIdentifiers

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
            DetailView()
        }
        .navigationTitle("KRemote")
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

#Preview {
    ContentView()
        .environment(AppModel())
        .frame(width: 1000, height: 640)
}
