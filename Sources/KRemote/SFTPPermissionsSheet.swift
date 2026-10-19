import SwiftUI
import KRemoteCore

/// chmod / chown for one selection, with the rwx checkboxes and the octal field
/// kept in step in both directions.
///
/// The mode arithmetic lives in `PermissionSet` (core, unit-tested); this view is
/// only the editor. Two rules it has to honour:
///
/// * typing `644` immediately ticks the right boxes, and toggling a box rewrites
///   the number — neither field is ever the stale one;
/// * a half-typed or impossible number (`8`, `abc`, five digits) is refused rather
///   than silently reinterpreted, because applying the wrong mode to a file is
///   exactly the mistake this sheet must not make.
struct SFTPPermissionsSheet: View {
    /// What the sheet is about: one name, or "3 items".
    let subject: String
    let entries: [RemoteEntry]
    let session: SFTPSession
    /// Called with the batch result once Apply has run, so the window can show one
    /// summary instead of the sheet showing its own.
    let onFinish: (BatchOutcome) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var permissions: PermissionSet
    @State private var octalText: String
    @State private var ownerText: String
    @State private var groupText: String
    /// Non-nil when the typed octal text is not a mode.
    @State private var octalError: String?
    @State private var isApplying = false
    @State private var isRecursive = false
    /// The owner/group the server reported, so a change can be spotted.
    @State private var originalOwner: UInt32?
    @State private var originalGroup: UInt32?
    @State private var loadError: String?

    init(
        entries: [RemoteEntry],
        session: SFTPSession,
        onFinish: @escaping (BatchOutcome) -> Void
    ) {
        self.entries = entries
        self.session = session
        self.onFinish = onFinish
        self.subject = entries.count == 1 ? entries[0].name : "\(entries.count) items"
        // The first entry seeds the sheet. A mixed selection shows the first
        // item's mode with a note, rather than a blank sheet nobody can interpret.
        let initial = PermissionSet(modeBits: entries.first?.permissions.map { UInt16($0 & 0o7777) } ?? 0o644)
        _permissions = State(initialValue: initial)
        _octalText = State(initialValue: initial.octal)
        _ownerText = State(initialValue: entries.first?.attributes.uid.map(String.init) ?? "")
        _groupText = State(initialValue: entries.first?.attributes.gid.map(String.init) ?? "")
        _originalOwner = State(initialValue: entries.first?.attributes.uid)
        _originalGroup = State(initialValue: entries.first?.attributes.gid)
    }

    private var mixedModes: Bool {
        Set(entries.compactMap { $0.permissions.map { $0 & 0o7777 } }).count > 1
    }

    private var ownerChanged: Bool {
        UInt32(ownerText.trimmingCharacters(in: .whitespaces)) != originalOwner
    }

    private var groupChanged: Bool {
        UInt32(groupText.trimmingCharacters(in: .whitespaces)) != originalGroup
    }

    private var ownerInvalid: Bool {
        let trimmed = ownerText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return UInt32(trimmed) == nil
    }

    private var groupInvalid: Bool {
        let trimmed = groupText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return UInt32(trimmed) == nil
    }

    private var canApply: Bool {
        !isApplying && octalError == nil && !ownerInvalid && !groupInvalid && !mixedModes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let loadError {
                Text(loadError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            permissionsGrid
            ownerFields
            if mixedModes {
                Text("These items have different permissions. Choose one to edit them all, or open them one at a time.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Divider()
            footer
        }
        .padding(18)
        .frame(width: 420)
        .task { await loadCurrentValues() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Permissions")
                    .font(.headline)
                Text(subject)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var permissionsGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                Text("").frame(width: 62, alignment: .leading)
                Text("Read").frame(maxWidth: .infinity)
                Text("Write").frame(maxWidth: .infinity)
                Text("Execute").frame(maxWidth: .infinity)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            permissionRow("Owner", binding: $permissions.owner, special: nil)
            permissionRow("Group", binding: $permissions.group, special: nil)
            permissionRow("Other", binding: $permissions.other, special: nil)

            HStack(spacing: 14) {
                Toggle("Set UID", isOn: $permissions.setuid)
                Toggle("Set GID", isOn: $permissions.setgid)
                Toggle("Sticky", isOn: $permissions.sticky)
            }
            .toggleStyle(.checkbox)
            .font(.caption)
            .onChange(of: permissions.setuid) { _, _ in syncOctalFromBoxes() }
            .onChange(of: permissions.setgid) { _, _ in syncOctalFromBoxes() }
            .onChange(of: permissions.sticky) { _, _ in syncOctalFromBoxes() }

            HStack(spacing: 10) {
                Text("Octal")
                    .frame(width: 62, alignment: .leading)
                TextField("755", text: $octalText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 76)
                    .onChange(of: octalText) { _, newValue in applyOctaText(newValue) }
                    .accessibilityLabel("Octal mode")
                Text(permissions.symbolic)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .font(.callout)

            if let octalError {
                Text(octalError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Octal mode error")
            } else if permissions.isDeniedToEveryone {
                Text("This removes read, write and execute from everyone, including you.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func permissionRow(
        _ title: String,
        binding: Binding<PermissionClass>,
        special: String?
    ) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .frame(width: 62, alignment: .leading)
            Toggle("", isOn: binding.read)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .accessibilityLabel("\(title) read")
            Toggle("", isOn: binding.write)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .accessibilityLabel("\(title) write")
            Toggle("", isOn: binding.execute)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .accessibilityLabel("\(title) execute")
        }
        .toggleStyle(.checkbox)
        .font(.callout)
        .onChange(of: binding.wrappedValue) { _, _ in syncOctalFromBoxes() }
    }

    private var ownerFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Owner")
                    .frame(width: 62, alignment: .leading)
                TextField("uid", text: $ownerText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 76)
                    .accessibilityLabel("Owner user id")
                Text("Group")
                    .frame(width: 46, alignment: .trailing)
                TextField("gid", text: $groupText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 76)
                    .accessibilityLabel("Owner group id")
                Spacer()
            }
            if ownerInvalid || groupInvalid {
                Text("User and group ids are numbers.")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if !ownerText.isEmpty || !groupText.isEmpty {
                Text("Changing the owner usually needs root. KRemote will retry over sudo when this connection allows it.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack {
            if entries.contains(where: \.isDirectory) {
                Toggle("Apply to folder contents", isOn: $isRecursive)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .disabled(true)
                    .help("Recursive chmod is not part of 1.8.0")
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(isApplying ? "Applying…" : "Apply") {
                Task { await apply() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canApply)
            .accessibilityLabel("Apply permissions to \(subject)")
        }
    }

    // MARK: - Sync

    /// A checkbox changed: rewrite the number. The field is never the authority
    /// while a box has focus, which is what keeps the two in step.
    private func syncOctalFromBoxes() {
        let updated = permissions.octal
        if octalText != updated { octalText = updated }
        octalError = nil
    }

    /// The number changed: adopt it, or say why not.
    private func applyOctaText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            // Mid-edit: an empty field is not an error yet, but Apply must stay off.
            octalError = "Enter a mode such as 644 or 0755."
            return
        }
        guard let parsed = PermissionSet.parse(octal: trimmed) else {
            octalError = "Use 3 or 4 octal digits (0–7), for example 644."
            return
        }
        octalError = nil
        // Adopt the parsed value so unsupported digits cannot linger in the field,
        // but leave the text as typed so the caret does not jump.
        permissions = parsed
    }

    /// Re-reads the first entry so a sheet opened from a stale row shows the
    /// server's current values, not the listing's snapshot.
    private func loadCurrentValues() async {
        guard let first = entries.first else { return }
        guard let attributes = await session.info(for: first) else {
            loadError = "The server did not report this item's attributes."
            return
        }
        if let mode = attributes.permissions {
            let parsed = PermissionSet(modeBits: UInt16(mode & 0o7777))
            permissions = parsed
            octalText = parsed.octal
        }
        if let uid = attributes.uid {
            originalOwner = uid
            ownerText = String(uid)
        }
        if let gid = attributes.gid {
            originalGroup = gid
            groupText = String(gid)
        }
        loadError = nil
    }

    private func apply() async {
        isApplying = true
        let owner = ownerChanged ? UInt32(ownerText.trimmingCharacters(in: .whitespaces)) : nil
        let group = groupChanged ? UInt32(groupText.trimmingCharacters(in: .whitespaces)) : nil
        let outcome = await session.applyPermissions(
            permissions, owner: owner, group: group, to: entries
        )
        isApplying = false
        dismiss()
        onFinish(outcome)
    }
}
