import SwiftUI
import KRemoteCore

/// Ready-made diagnostics, grouped, run on the focused SSH session.
///
/// Unlike a snippet these are not saved and not confirmed: they are read-only by
/// construction (the catalogue is tested for that), so a confirmation step would only
/// teach people to click through dialogs. Anything that changes state belongs in a
/// snippet, where the confirmation already lives.
struct RemoteToolsMenuButton: View {
    @Environment(AppModel.self) private var model

    private var targetSession: Session? {
        guard let session = model.focusedSession,
              let node = model.find(session.nodeID), node.supportsSSH
        else { return nil }
        return session
    }

    var body: some View {
        Menu {
            ForEach(RemoteTool.groups, id: \.self) { group in
                Menu(group) {
                    ForEach(RemoteTool.tools(in: group)) { tool in
                        Button {
                            model.runTool(tool)
                        } label: {
                            // The name and what it answers, so the menu is usable
                            // without knowing the command by heart.
                            Text("\(tool.name) — \(tool.summary)")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "wrench.and.screwdriver")
        }
        .menuIndicator(.hidden)
        .help("Run a diagnostic on the focused SSH session")
        .accessibilityLabel("Remote tools")
        .disabled(targetSession == nil)
    }
}
