import SwiftUI
import KRemoteCore

/// Modal editor for a connection or folder. Binds to a `ConnectionDraft`, so a
/// cancelled edit never touches the live tree.
///
/// A folder holds **credentials** for its children (username, password, identity
/// file) — not protocol, port or host, which belong to each connection because a
/// folder commonly mixes SSH, RDP and HTTPS children. Blank credential fields are
/// shown with the value they inherit as the placeholder.
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

                if isFolder {
                    Section {
                        Text("Credentials set here are inherited by every connection in this folder, unless a connection overrides them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Username", text: $draft.username, prompt: Text(inheritedUsernamePlaceholder))
                        TextField("Identity File", text: $draft.identityFile, prompt: Text(inheritedIdentityPlaceholder))
                            .help("Private key passed as ssh -i. Blank means ssh picks (config, agent or default keys).")
                        SecureField("Password", text: $draft.password)
                            .help("Stored in the macOS Keychain, never written to disk as plain text.")
                    } header: {
                        Text("Credentials for this folder")
                    }
                } else {
                    Section("Connection") {
                        TextField("Host", text: $draft.host)
                        TextField("Protocol", text: $draft.protocolName, prompt: Text("SSH"))
                        TextField("Port", value: $draft.port, format: .number, prompt: Text(portPlaceholder))
                            .frame(maxWidth: 140)
                        TextField("Remote Command", text: $draft.remoteCommand)
                            .help("Run this instead of an interactive shell. Blank means a normal shell.")
                    }
                    Section("Credentials") {
                        TextField("Username", text: $draft.username, prompt: Text(inheritedUsernamePlaceholder))
                        TextField("Identity File", text: $draft.identityFile, prompt: Text(inheritedIdentityPlaceholder))
                            .help("Private key passed as ssh -i. Blank means ssh picks (config, agent or default keys).")
                        SecureField("Password", text: $draft.password)
                            .help("Stored in the macOS Keychain, never written to disk as plain text.")
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

    private var inheritedUsernamePlaceholder: String {
        draft.username.isEmpty ? (inherited?.username ?? "") : ""
    }
    private var inheritedIdentityPlaceholder: String {
        draft.identityFile.isEmpty ? (inherited?.identityFile ?? "") : ""
    }
    /// Port left blank resolves to the protocol's default (on the connection's
    /// own protocol, since that no longer inherits).
    private var portPlaceholder: String {
        let protocolName = draft.protocolName.isEmpty ? "SSH" : draft.protocolName
        let fallback = RemoteProtocol(protocolName).defaultPort
        return String(fallback > 0 ? fallback : 22)
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
