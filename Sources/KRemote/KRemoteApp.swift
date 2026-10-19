import SwiftUI
import KRemoteCore

@main
struct KRemoteApp: App {
    @State private var model = AppModel()
    @State private var showUpdate = false
    /// Silently checked once at launch; drives the "update available" hint.
    @State private var updateAvailable: UpdateInfo?
    /// Persisted channel selection. `@AppStorage` (rather than reading
    /// `UpdateChecker.channel` once) is what makes the launch check follow a
    /// channel switch made in Software Update: the value changes, and the
    /// `onChange` below re-queries the appcast that channel points at.
    @AppStorage("updateChannel") private var channelRaw = UpdateChannel.stable.rawValue

    private var channel: UpdateChannel {
        UpdateChannel(rawValue: channelRaw) ?? .stable
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 940, minHeight: 580)
                .sheet(isPresented: $showUpdate) { UpdateView() }
                .task { await silentCheck() }
                .onChange(of: channelRaw) { _, _ in
                    Task { await silentCheck() }
                }
        }
        // System title bar back on (the app-drawn header did not work out), so
        // the tabs go back into the toolbar, centred.
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            // No "New" document semantics yet.
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { showUpdate = true }
                if let updateAvailable {
                    Button("Update Available (\(updateAvailable.latestVersion))…") { showUpdate = true }
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

    /// Silent check; the result only surfaces as a menu item. It asks for the
    /// channel the user selected — a beta tester gets beta (plus the stable
    /// fallback), a stable user only ever sees finished releases.
    @MainActor
    private func silentCheck() async {
        guard let info = try? await UpdateChecker.check(channel: channel), info.isNewer else {
            updateAvailable = nil
            return
        }
        updateAvailable = info
    }
}
