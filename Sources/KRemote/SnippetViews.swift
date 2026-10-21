import SwiftUI
import KRemoteCore

/// The snippets toolbar button: pick a saved script, confirm it, run it.
///
/// A `Menu` rather than a popover so the list behaves like every other command menu
/// on macOS — type-ahead, keyboard navigation, and it closes on selection.
struct SnippetMenuButton: View {
    @Environment(AppModel.self) private var model

    /// Snippets run in a shell, so the button is only useful when an SSH session has
    /// focus. Falling back to the sidebar selection would let the user think a script
    /// ran when no shell existed.
    private var targetSession: Session? {
        guard let session = model.focusedSession,
              let node = model.find(session.nodeID), node.supportsSSH
        else { return nil }
        return session
    }

    var body: some View {
        Menu {
            if model.snippets.isEmpty {
                Text("No snippets yet")
            } else {
                ForEach(model.snippets) { snippet in
                    Button(snippet.name) { model.requestSnippet(snippet) }
                        .disabled(!snippet.isRunnable)
                }
                Divider()
                // Editing lives on the same list as running: a snippet that can only
                // be added is a snippet the user will eventually get wrong.
                Menu("Edit") {
                    ForEach(model.snippets) { snippet in
                        Button(snippet.name) { model.editingSnippetID = snippet.id }
                    }
                }
                Divider()
            }
            Button("New Snippet…") { model.isCreatingSnippet = true }
        } label: {
            Image(systemName: "text.badge.plus")
        }
        .menuIndicator(.hidden)
        .help("Run a saved snippet on the focused SSH session")
        .accessibilityLabel("Snippets")
        .disabled(targetSession == nil)
    }
}

/// Asks before a snippet runs.
///
/// Every run is confirmed, including one the user has run before: a script is code,
/// and a menu one click away from a production server should not be a trigger. The
/// dialog shows the script itself rather than its name, because the name is the part
/// the user already trusts.
struct SnippetConfirmSheet: View {
    @Environment(AppModel.self) private var model
    let pending: AppModel.PendingSnippet

    /// Edited here, handed to the model only on Run. Holding them locally keeps the
    /// sheet cancellable: half-typed values must not linger in the model.
    @State private var values: [String: String] = [:]

    private var isDestructive: Bool {
        SnippetLibrary.isDestructive(pending.snippet)
    }

    private var run: SnippetRun {
        SnippetRun(snippet: pending.snippet, values: values)
    }

    /// A run whose required fields are still empty cannot start: the script would
    /// silently receive an empty string.
    private var canRun: Bool { run.canRun }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: isDestructive ? "exclamationmark.triangle.fill" : "text.badge.plus")
                    .foregroundStyle(isDestructive ? .orange : .accentColor)
                Text(isDestructive ? "Run a destructive snippet?" : "Run this snippet?")
                    .font(.headline)
            }

            HStack(spacing: 6) {
                Text(pending.snippet.name)
                    .font(.callout.weight(.medium))
                Text("on")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(model.sessionTitle(for: pending.sessionID) ?? "this server")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if !pending.snippet.parameters.isEmpty {
                parameterFields
            }

            ScrollView {
                Text(SnippetLibrary.preview(of: pending.snippet))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 180)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor))
            )

            if isDestructive {
                Text("This script looks like it deletes or stops something. Check the server above.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.cancelSnippet() }
                    .keyboardShortcut(.cancelAction)
                Button(isDestructive ? "Run Anyway" : "Run") {
                    model.confirmSnippet(values: values)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(isDestructive ? .orange : .accentColor)
                .disabled(!canRun)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            // Seed once from the defaults the model prepared. `onAppear` rather than an
            // initialiser because the sheet is rebuilt on every model change.
            if values.isEmpty { values = pending.values }
        }
    }

    /// The value fields, in the order the parameters were defined.
    private var parameterFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(pending.snippet.parameters) { parameter in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(parameter.name)
                            .font(.system(size: 11, design: .monospaced))
                        if parameter.isRequired {
                            Text("required")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        } else {
                            Text("default")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if parameter.isSecret {
                        // A password typed into a script form should not sit on screen
                        // while the user reads the script below it.
                        SecureField(parameter.note.isEmpty ? parameter.name : parameter.note,
                                    text: binding(for: parameter))
                            .textFieldStyle(.roundedBorder)
                    } else {
                        TextField(parameter.note.isEmpty ? parameter.name : parameter.note,
                                  text: binding(for: parameter))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
            }

            if !run.missingRequired.isEmpty {
                Text("Fill in: " + run.missingRequired.map(\.name).joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func binding(for parameter: SnippetParameter) -> Binding<String> {
        Binding(
            get: { values[parameter.name] ?? parameter.defaultValue },
            set: { values[parameter.name] = $0 }
        )
    }
}

/// Creates or edits a snippet.
struct SnippetEditorView: View {
    @Environment(AppModel.self) private var model
    /// nil for a new snippet.
    let snippetID: Snippet.ID?
    let onClose: () -> Void

    @State private var name = ""
    /// The script. Not called `body`: that is the View's own property.
    @State private var script = ""
    /// Guards against a stray Return in the name field saving a half-written script.
    @State private var loaded = false
    /// The parameter list, edited in place.
    @State private var parameters: [SnippetParameter] = []

    private var isNew: Bool { snippetID == nil }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !script.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "New Snippet" : "Edit Snippet")
                .font(.headline)

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 4) {
                Text("Script")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $script)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 260)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color(nsColor: .separatorColor))
                    )
            }

            parameterSection

            Text("Runs with the server's sh. The body is sent as a file, so quotes, heredocs and several lines are safe.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        if let snippetID { model.deleteSnippet(snippetID) }
                        onClose()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 660)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            guard let snippetID, let existing = model.snippets.first(where: { $0.id == snippetID })
            else { return }
            name = existing.name
            script = existing.body
            parameters = existing.parameters
        }
    }

    /// The parameter list plus the "detect from script" helper.
    private var parameterSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Parameters")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Detect from Script") { detectParameters() }
                    .controlSize(.small)
                    .help("Find $VARIABLES in the script and add them to this list")
                Button {
                    parameters.append(SnippetParameter(name: nextParameterName()))
                } label: {
                    Image(systemName: "plus")
                }
                .controlSize(.small)
                .help("Add a parameter by hand")
            }

            if parameters.isEmpty {
                Text("No parameters. The script runs as written.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach($parameters) { $parameter in
                            parameterRow($parameter)
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
        }
    }

    private func parameterRow(_ parameter: Binding<SnippetParameter>) -> some View {
        HStack(spacing: 6) {
            TextField("NAME", text: parameter.name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 130)
                // A name that is not a shell identifier cannot be exported, so it is
                // flagged rather than silently producing a command that does nothing.
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(
                            SnippetParameter.isValidName(parameter.wrappedValue.name)
                                ? Color.clear : Color.orange,
                            lineWidth: 1
                        )
                )

            TextField("default (optional)", text: parameter.defaultValue)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))

            Toggle("secret", isOn: parameter.isSecret)
                .toggleStyle(.checkbox)
                .font(.caption2)
                .help("Hide the value in the run dialog")

            Button {
                parameters.removeAll { $0.id == parameter.wrappedValue.id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove this parameter")
        }
    }

    /// Adds every `$VARIABLE` the script mentions that is not already listed.
    ///
    /// Deliberately additive: detection never removes a parameter the user defined,
    /// because a script may read a variable that only appears in a string the scanner
    /// cannot see through.
    private func detectParameters() {
        let existing = Set(parameters.map(\.name))
        for name in SnippetParameterScanner.scan(script) where !existing.contains(name) {
            parameters.append(SnippetParameter(name: name))
        }
    }

    private func nextParameterName() -> String {
        var index = parameters.count + 1
        let taken = Set(parameters.map(\.name))
        while taken.contains("PARAM\(index)") { index += 1 }
        return "PARAM\(index)"
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !script.isEmpty else { return }

        // Keep the existing id and position so editing does not reorder the menu.
        let existing = snippetID.flatMap { id in model.snippets.first { $0.id == id } }
        model.upsertSnippet(Snippet(
            id: existing?.id ?? UUID(),
            name: trimmed,
            body: script,
            sortIndex: existing?.sortIndex ?? (model.snippets.count),
            parameters: parameters.filter { $0.isValidName }
        ))
        onClose()
    }
}
