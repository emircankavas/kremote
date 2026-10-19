import SwiftUI
import KRemoteCore

/// Modal editor for a connection or folder. Binds to a `ConnectionDraft`, so a
/// cancelled edit never touches the live tree.
///
/// A folder holds **credentials and RDP defaults** for its children (username,
/// password, identity file, domain, resolution, colour depth, redirections) —
/// not protocol, port or host, which belong to each connection because a folder
/// commonly mixes SSH, RDP and HTTPS children. Every inheritable field left blank
/// shows the value it inherits as its placeholder.
struct ConnectionEditorView: View {
    @Environment(AppModel.self) private var model

    let nodeID: ConnectionNode.ID
    let onClose: () -> Void

    @State private var draft = ConnectionDraft(id: UUID(), name: "")
    /// The node the draft was loaded from. Using the id (rather than a plain
    /// "loaded" flag) means the draft is reloaded whenever the editor is pointed
    /// at a different node — SwiftUI can reuse a sheet's content view, and a bare
    /// flag would then leave the previous node's data in the fields.
    @State private var loadedNodeID: ConnectionNode.ID?

    private var node: ConnectionNode? { model.find(nodeID) }
    private var isFolder: Bool { node?.isFolder ?? false }
    /// The draft's resolved protocol, so the RDP section follows the field
    /// without waiting for a save.
    private var isRDP: Bool { draft.isRDP }

    /// What the node would resolve to with the parent's values folded in.
    /// Used only to label inheritance placeholders.
    private var inherited: EffectiveConnection? {
        guard let parentID = ConnectionNode.parentID(of: nodeID, in: model.roots) else { return nil }
        // Folders' stored passwords are lazy too, so resolve them before showing
        // inherited values as placeholders.
        model.hydrateCredentials(for: parentID)
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
                        TextField("Domain", text: domainBinding, prompt: Text(inheritedDomainPlaceholder))
                            .help("Windows domain, or a user@realm name. Blank is inherited from the folder.")
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
                        protocolField
                        TextField("Port", value: $draft.port, format: .number, prompt: Text(portPlaceholder))
                            .frame(maxWidth: 140)
                        if !isRDP {
                            TextField("Remote Command", text: $draft.remoteCommand)
                                .help("Run this instead of an interactive shell. Blank means a normal shell.")
                        }
                    }
                    if !isRDP {
                        Section("Credentials") {
                            TextField("Username", text: $draft.username, prompt: Text(inheritedUsernamePlaceholder))
                            TextField("Identity File", text: $draft.identityFile, prompt: Text(inheritedIdentityPlaceholder))
                                .help("Private key passed as ssh -i. Blank means ssh picks (config, agent or default keys).")
                            SecureField("Password", text: $draft.password)
                                .help("Stored in the macOS Keychain, never written to disk as plain text.")
                        }
                        Section("SFTP") {
                            Toggle("Retry refused file operations with sudo", isOn: $draft.usesSudo)
                                .help(
                                    """
                                    When a file operation is refused, KRemote retries it once over a \
                                    second SSH connection running the sftp subsystem under sudo. \
                                    Needs the password above; it is written to sudo's stdin and never logged.
                                    """
                                )
                            Text("On by default. Needs the password above and sudo rights on the server. Only the refused operation is retried over a second connection; the rest of the session stays unprivileged.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !isFolder, isRDP {
                    rdpCredentialsSection
                }
                if isFolder || isRDP {
                    rdpOptionsSection
                }
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .frame(width: 460)
        .onAppear(perform: loadDraft)
    }

    // MARK: - Protocol

    private var protocolField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("Protocol", text: $draft.protocolName, prompt: Text("SSH"))
                Menu {
                    ForEach(Self.commonProtocols, id: \.self) { name in
                        Button(name) { draft.protocolName = name }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Pick a common protocol")
            }
            if isRDP {
                Text("RDP connections are opened with FreeRDP.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static let commonProtocols = ["SSH2", "RDP", "VNC", "Telnet", "HTTP", "HTTPS"]

    // MARK: - RDP

    private var rdpCredentialsSection: some View {
        Section("RDP credentials") {
            TextField("Username", text: $draft.username, prompt: Text(inheritedUsernamePlaceholder))
            TextField("Domain", text: domainBinding, prompt: Text(inheritedDomainPlaceholder))
                .help("Windows domain, or a user@realm name. Blank is inherited from the folder.")
            SecureField("Password", text: $draft.password)
                .help("Stored in the macOS Keychain, never written to disk as plain text.")
        }
    }

    private var rdpOptionsSection: some View {
        Section {
            if isFolder {
                Text("RDP defaults set here are inherited by every RDP connection in this folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Resolution", selection: $draft.rdp.resolution) {
                Text("Inherit").tag(RDPResolutionMode?.none)
                ForEach(RDPResolutionMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(RDPResolutionMode?.some(mode))
                }
            }
            if draft.rdp.resolution == .custom {
                HStack(spacing: 8) {
                    TextField("Width", value: $draft.rdp.customWidth, format: .number)
                        .frame(width: 90)
                    Text("×").foregroundStyle(.secondary)
                    TextField("Height", value: $draft.rdp.customHeight, format: .number)
                        .frame(width: 90)
                }
            }

            Picker("Colour depth", selection: $draft.rdp.colorDepth) {
                Text("Inherit").tag(Int?.none)
                ForEach([8, 16, 24, 32], id: \.self) { depth in
                    Text("\(depth)-bit").tag(Int?.some(depth))
                }
            }

            triState("Redirect clipboard", $draft.rdp.redirectClipboard)
            triState("Redirect drives", $draft.rdp.redirectDrives)
            triState("Redirect printers", $draft.rdp.redirectPrinters)
            triState("Redirect sound", $draft.rdp.redirectSound)
            triState("Redirect key combinations", $draft.rdp.redirectKeys)
        } header: {
            Text(isFolder ? "RDP defaults for this folder" : "RDP")
        }
    }

    /// An inheritable boolean: a three-way picker rather than a toggle, so
    /// "not set on this node" stays visible and distinct from "off".
    private func triState(_ label: String, _ value: Binding<Bool?>) -> some View {
        Picker(label, selection: value) {
            Text("Inherit").tag(Bool?.none)
            Text("On").tag(Bool?.some(true))
            Text("Off").tag(Bool?.some(false))
        }
        .pickerStyle(.menu)
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: isFolder ? "folder" : (isRDP ? "display" : "terminal"))
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
                Text(resolved.editorSummary)
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
    private var inheritedDomainPlaceholder: String {
        let inheritedDomain = inherited?.rdp.domain ?? ""
        return (draft.rdp.domain ?? "").isEmpty ? inheritedDomain : ""
    }
    /// Port left blank resolves to the protocol's default (on the connection's
    /// own protocol, since that no longer inherits).
    private var portPlaceholder: String {
        let protocolName = draft.protocolName.isEmpty ? "SSH" : draft.protocolName
        let fallback = RemoteProtocol(protocolName).defaultPort
        return String(fallback > 0 ? fallback : 22)
    }

    /// `domain` is optional in the draft but a plain text field in the UI;
    /// whitespace is normalised out so an all-space value reads as "inherit".
    private var domainBinding: Binding<String> {
        Binding(
            get: { draft.rdp.domain ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                draft.rdp.domain = trimmed.isEmpty ? nil : trimmed
            }
        )
    }

    // MARK: - Actions

    private func loadDraft() {
        guard loadedNodeID != nodeID, let node else { return }
        // The stored password is loaded lazily, so pull this node's (and its
        // folders') out of the store now that the editor is opening.
        model.hydrateCredentials(for: nodeID)
        draft = ConnectionDraft(from: node)
        loadedNodeID = nodeID
    }

    private func save() {
        model.apply(draft)
        onClose()
    }
}

private extension EffectiveConnection {
    /// The editor footer shows the RDP summary for RDP connections and the usual
    /// `protocol://user@host:port` line otherwise.
    var editorSummary: String {
        RemoteProtocol(protocolName.isEmpty ? "SSH" : protocolName).isRDPFamily
            ? rdp.summary
            : summary
    }
}
