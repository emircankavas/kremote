import SwiftUI
import KRemoteCore

@main
struct KRemoteApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 940, minHeight: 580)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            // No "New" document semantics yet.
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("New Connection") {
                    model.addConnection(inFolder: model.selectedFolderID)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Folder") {
                    model.addFolder(inFolder: model.selectedFolderID)
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
                Divider()
                Button("Edit…") {
                    if let id = model.selectedNodeID { model.editingNodeID = id }
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(model.selectedNodeID == nil)
            }
        }
    }
}
