import SwiftUI
import KRemoteCore

/// Modal editor for a connection or folder. Binds to a `ConnectionDraft`, so a
/// cancelled edit never touches the live tree.
///
/// Connection fields left blank (host, username, port) are shown as inheriting
/// from the parent folder — the resolved value appears as a placeholder.
struct ConnectionEditorView: View {
    @Environment(AppModel.self) private var model

    let nodeID: ConnectionNode.ID
    let onClose: () -> Void

    @State private var draft = ConnectionDraft(id: UUID(), name: "")
    @State private var loaded = false

    private var node: ConnectionNode? { model.find(nodeID) }
    private var isFolder: Bool { node?.isFolder ?? false }

    /// What the node would resolve to with the parent's values folded in.
    /// Used only to label inheritance placeholders.
    private var inherited: EffectiveConnection? {
        guard let parentID = ConnectionNode.parentID(of: nodeID, in: model.roots) else { return nil }
        return model.effective(parentID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Form {
                Section("General") {
                    TextField("Name", text: $draft.name)
                }

                if !isFolder {
                    Section("Connection") {
                        if !inheritedHostPlaceholder.isEmpty {
                            Text("Host is inherited from the parent folder.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        TextField("Host", text: $draft.host, prompt: Text(inheritedHostPlaceholder))
                        TextField("Username", text: $draft.username, prompt: Text(inheritedUsernamePlaceholder))
                        TextField("Protocol", text: $draft.protocolName, prompt: Text(inheritedProtocolPlaceholder))
                        TextField("Port", value: $draft.port, format: .number, prompt: Text(inheritedPortPlaceholder))
                            .frame(maxWidth: 140)
                        TextField("Identity File", text: $draft.identityFile, prompt: Text(inheritedIdentityPlaceholder))
                            .help("Private key passed as ssh -i. Blank means ssh picks (config, agent or default keys).")
                        SecureField("Password", text: $draft.password)
                            .help("Stored in the macOS Keychain, never written to disk as plain text.")
                        TextField("Remote Command", text: $draft.remoteCommand, prompt: Text(inheritedCommandPlaceholder))
                            .help("Run this instead of an interactive shell. Blank means a normal shell.")
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .frame(width: 440)
        .onAppear(perform: loadDraft)
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: isFolder ? "folder" : "terminal")
                .foregroundStyle(.secondary)
            Text(isFolder ? "Edit Folder" : "Edit Connection")
                .font(.headline)
            Spacer()
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            if let resolved = model.effective(nodeID), !isFolder {
                Text(resolved.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Cancel", role: .cancel, action: onClose)
                .keyboardShortcut(.cancelAction)
            Button("Save", action: save)
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    // MARK: - Inheritance placeholders

    private var inheritedHostPlaceholder: String {
        draft.host.isEmpty ? (inherited?.host ?? "") : ""
    }
    private var inheritedUsernamePlaceholder: String {
        draft.username.isEmpty ? (inherited?.username ?? "") : ""
    }
    private var inheritedProtocolPlaceholder: String {
        draft.protocolName.isEmpty ? (inherited?.protocolName ?? "SSH") : ""
    }
    private var inheritedPortPlaceholder: String {
        draft.port == 0 ? "\(inherited?.port ?? 22)" : ""
    }
    private var inheritedIdentityPlaceholder: String {
        draft.identityFile.isEmpty ? (inherited?.identityFile ?? "") : ""
    }
    private var inheritedCommandPlaceholder: String {
        draft.remoteCommand.isEmpty ? (inherited?.remoteCommand ?? "") : ""
    }

    // MARK: - Actions

    private func loadDraft() {
        guard !loaded, let node else { return }
        draft = ConnectionDraft(from: node)
        loaded = true
    }

    private func save() {
        model.apply(draft)
        onClose()
    }
}
