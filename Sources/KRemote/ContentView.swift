import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

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
        .alert("KRemote", isPresented: errorPresented) {
            Button("OK", role: .cancel) { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })
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
