import SwiftUI
import KRemoteCore

/// The remote text editor: one sheet per open file.
///
/// Deliberately plain — a monospaced text area, the path, and Save. Syntax colouring is
/// not the point here; the point is not having to leave the app to change one line of a
/// config file, without silently destroying somebody else's edit.
struct RemoteEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let session: SFTPSession
    let path: String

    @State private var document: RemoteFileDocument?
    @State private var loadError: String?
    @State private var saveError: String?
    /// Set when a save was refused because the file changed underneath.
    @State private var conflictMessage: String?
    /// True once the user has seen the conflict and asked to overwrite.
    @State private var overwriteConfirmed = false
    @State private var isSaving = false
    /// Guards the close button: losing an edited buffer to a stray click is the kind of
    /// thing that makes people stop trusting an editor.
    @State private var showDiscardPrompt = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 440)
        .task { await load() }
        .confirmationDialog(
            "Discard your changes?",
            isPresented: $showDiscardPrompt,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("\(document?.displayName ?? "This file") has unsaved changes.")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(document?.displayName ?? (path as NSString).lastPathComponent)
                    .font(.callout.weight(.medium))
                Text(path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if document?.isDirty == true {
                Circle()
                    .fill(.orange)
                    .frame(width: 7, height: 7)
                    .help("Unsaved changes")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private var content: some View {
        if let loadError {
            message(loadError, symbol: "exclamationmark.triangle", tint: .orange)
        } else if let document, document.isBinary {
            message("This looks like a binary file. It is not opened for editing.",
                    symbol: "doc.zipper", tint: .secondary)
        } else if let document {
            VStack(spacing: 0) {
                if document.hadDecodingLoss {
                    // Saving rewrites the file as UTF-8, which may not be what it was.
                    // Better said before the user finds out the hard way.
                    notice("This file is not valid UTF-8. Saving will rewrite it as UTF-8.")
                }
                TextEditor(text: binding)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(4)
            }
        } else {
            ProgressView("Reading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if let conflictMessage {
                Label(conflictMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            Spacer()
            Button("Close") { attemptClose() }
                .keyboardShortcut(.cancelAction)
            Button(saveTitle) {
                Task { await save() }
            }
            .keyboardShortcut("s")
            .buttonStyle(.borderedProminent)
            .tint(overwriteConfirmed ? .orange : .accentColor)
            .disabled(!canSave)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var saveTitle: String {
        if isSaving { return "Saving…" }
        return overwriteConfirmed ? "Overwrite" : "Save"
    }

    private var canSave: Bool {
        guard let document, !document.isBinary, document.isDirty, !isSaving else { return false }
        return true
    }

    private func notice(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.caption2)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.08))
    }

    private func message(_ text: String, symbol: String, tint: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var binding: Binding<String> {
        Binding(
            get: { document?.text ?? "" },
            set: { newValue in
                document?.text = newValue
                // Editing invalidates a previous overwrite decision: the buffer the user
                // agreed to write is no longer the buffer on screen.
                overwriteConfirmed = false
                conflictMessage = nil
            }
        )
    }

    // MARK: - Load / save

    private func load() async {
        do {
            let data = try await session.loadFile(path)
            document = RemoteFileDocument.make(
                path: path,
                data: data.data,
                size: data.size,
                modified: data.modified
            )
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Writes the buffer, refusing once when the file changed underneath.
    ///
    /// Two-step on purpose: the first press explains, the second overwrites. One press
    /// that either writes blindly or refuses forever is worse in both directions — one
    /// loses data, the other traps the user when they *do* want their version.
    private func save() async {
        guard let document, !document.isBinary else { return }
        isSaving = true
        saveError = nil
        defer { isSaving = false }

        do {
            if !overwriteConfirmed {
                let info = try? await session.fileInfo(path)
                if document.conflictsWith(currentSize: info?.size, currentModified: info?.modified) {
                    overwriteConfirmed = true
                    conflictMessage = "The file changed on the server since you opened it. "
                        + "Press Overwrite to save your version anyway."
                    return
                }
            }

            try await session.saveFile(path, text: document.text)

            // Re-baseline against what was just written, so the next save does not
            // conflict with our own change.
            let written = try await session.loadFile(path)
            self.document = RemoteFileDocument.make(
                path: path,
                data: written.data,
                size: written.size,
                modified: written.modified
            )
            conflictMessage = nil
            overwriteConfirmed = false
        } catch {
            saveError = "Could not save: \(error.localizedDescription)"
        }
    }

    private func attemptClose() {
        if document?.isDirty == true {
            showDiscardPrompt = true
        } else {
            dismiss()
        }
    }
}
