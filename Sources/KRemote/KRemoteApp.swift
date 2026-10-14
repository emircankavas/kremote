import SwiftUI
import KRemoteCore

@main
struct KRemoteApp: App {
    @State private var model = AppModel()
    @State private var showUpdate = false
    /// Silently checked once at launch; drives the "update available" hint.
    @State private var updateAvailable: UpdateInfo?

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 940, minHeight: 580)
                .sheet(isPresented: $showUpdate) { UpdateView() }
                .task {
                    // Silent launch check; the result only surfaces as a menu item.
                    guard let info = try? await UpdateChecker.check(), info.isNewer else { return }
                    updateAvailable = info
                }
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            // No "New" document semantics yet.
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { showUpdate = true }
                if updateAvailable != nil {
                    Button("Update Available (\(updateAvailable?.latestVersion ?? ""))…") { showUpdate = true }
                }
            }
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
            CommandGroup(after: .importExport) {
                Button("Import mRemoteNG confCons.xml…") {
                    model.isImportingConfCons = true
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
            CommandMenu("Session") {
                Button("Toggle Split View") {
                    model.setSplit(!model.splitMode, panes: model.splitMode ? nil : 2)
                }
                .keyboardShortcut("d", modifiers: .command)
                Divider()
                ForEach(2...PaneLayout.maximum, id: \.self) { count in
                    Button("\(count) Panes") { model.setSplit(true, panes: count) }
                }
            }
        }
    }
}
