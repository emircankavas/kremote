import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KRemoteCore

/// How the browser draws a directory. Persisted app-wide (`sftpViewMode`), not
/// per connection — the card asks for one setting for the whole app.
enum SFTPViewMode: String, CaseIterable, Identifiable {
    case list
    case icons

    var id: String { rawValue }
    var icon: String { self == .list ? "list.bullet" : "square.grid.2x2" }
    var label: String { self == .list ? "List" : "Icons" }
}

/// Which column list view sorts by.
enum SFTPSortColumn: String, CaseIterable, Identifiable {
    case name, size, modified, permissions, owner

    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: return "Name"
        case .size: return "Size"
        case .modified: return "Date Modified"
        case .permissions: return "Permissions"
        case .owner: return "Owner"
        }
    }
    /// Fixed width for every column but the name, which takes what is left.
    var width: CGFloat? {
        switch self {
        case .name: return nil
        case .size: return 90
        case .modified: return 140
        case .permissions: return 110
        case .owner: return 70
        }
    }
    var alignment: Alignment {
        self == .size ? .trailing : .leading
    }
}

/// A Finder-like file browser for one connection.
///
/// Navigation shell only: transfers and file operations are the next card, so a
/// double-click on a *file* is deliberately a no-op here.
struct SFTPWindowView: View {
    let session: SFTPSession

    /// App-wide view mode — survives a window close and an app relaunch.
    @AppStorage("sftpViewMode") private var viewModeRaw = SFTPViewMode.list.rawValue
    /// Hidden files stay per user as well, the way Finder remembers ⇧⌘..
    @AppStorage("sftpShowHidden") private var showHidden = false

    @State private var selection: Set<String> = []
    /// Where a ⇧-click range is measured from.
    @State private var selectionAnchor: String?
    @State private var sortColumn: SFTPSortColumn = .name
    @State private var sortAscending = true
    @State private var goToPath = ""
    @State private var isGoToPresented = false
    @State private var isNewFolderPresented = false
    @State private var newFolderName = "untitled folder"
    @State private var renameTarget: RemoteEntry?
    @State private var renameDraft = ""
    @State private var deleteTarget: [RemoteEntry] = []
    /// How many entries a folder delete would remove, from the server, so the
    /// confirmation names a real number.
    @State private var deleteItemCount: Int?
    @State private var isDeletePresented = false
    @State private var permissionsTarget: RemoteEntry?
    /// Set while a compressed download is being assembled.
    @State private var compressProgress: CompressProgress?
    /// The permissions sheet for a whole selection (nil when it is one row).
    @State private var permissionsRequest: PermissionsRequest?
    /// A download batch waiting on the conflict answer, plus its conflict-free part.
    @State private var pendingConflicts: [(entry: RemoteEntry, destination: URL)] = []
    @State private var pendingFreeDownloads: [(entry: RemoteEntry, destination: URL)] = []
    @State private var conflictName = ""
    @State private var conflictDirectory: URL?
    @State private var isConflictPresented = false
    /// One modal that needs the user's answer: a batch summary or a single failure.
    @State private var batchSheet: BatchPrompt?
    /// Get Info's target and the `stat` values for it.
    @State private var infoEntry: RemoteEntry?
    @State private var infoAttributes: SFTPAttributes?

    private var viewMode: SFTPViewMode {
        get { SFTPViewMode(rawValue: viewModeRaw) ?? .list }
        nonmutating set { viewModeRaw = newValue.rawValue }
    }

    var body: some View {
        sheets(alerts(layout))
    }

    /// The window's frame. Kept separate from the sheet/alert chain: one `body`
    /// holding all of it pushes the SwiftUI type checker past its limit.
    private var layout: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                shortcutsSidebar
                Divider()
                content
            }
            Divider()
            SFTPTransferPanel(session: session)
            Divider()
            statusBar
        }
        .frame(minWidth: 780, minHeight: 440)
        .navigationTitle(session.title)
        .task { await session.connect() }
        .background(
            // Return renames the selected item, the Finder behaviour the card asks
            // for; ⌘↓ opens a folder. Hidden buttons are the only way to bind a
            // bare key to an action in SwiftUI.
            Group {
                Button("") { renameSelection() }
                    .keyboardShortcut(.return, modifiers: [])
                Button("") { openSelection() }
                    .keyboardShortcut(.downArrow, modifiers: .command)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        )
        .onChange(of: session.path) { _, _ in
            selection = []
            selectionAnchor = nil
            session.selectedPath = nil
        }
        .onChange(of: session.entries) { _, _ in
            // A selection must not outlive its rows: "Get Info" after a delete
            // would otherwise act on something no longer listed.
            selection = SFTPSelection.pruned(selection, to: session.entries.map(\.path))
        }
    }

    /// The prompts that take a text answer or a yes/no.
    private func alerts<V: View>(_ view: V) -> some View {
        view
            .confirmationDialog(deleteTitle, isPresented: $isDeletePresented, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    let entries = deleteTarget
                    Task { report(await session.delete(entries)) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(deleteMessage)
            }
            .alert("New Folder", isPresented: $isNewFolderPresented) {
                TextField("Name", text: $newFolderName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    let name = newFolderName
                    Task {
                        if case .failure(let error) = await session.createFolder(named: name) {
                            batchSheet = .failure(error)
                        }
                    }
                }
            } message: {
                Text("Create a folder in \(session.path).")
            }
            .alert("Rename", isPresented: renamePresented, presenting: renameTarget) { entry in
                TextField("Name", text: $renameDraft)
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    let name = renameDraft
                    Task {
                        if case .failure(let error) = await session.rename(entry, to: name) {
                            batchSheet = .failure(error)
                        }
                    }
                }
            } message: { entry in
                Text("Rename \(entry.name).")
            }
    }

    /// The sheets and the overwrite question.
    private func sheets<V: View>(_ view: V) -> some View {
        view
            .sheet(isPresented: $isGoToPresented) { goToSheet }
            .sheet(item: $permissionsTarget) { entry in
                SFTPPermissionsSheet(entries: [entry], session: session) { outcome in
                    permissionsTarget = nil
                    report(outcome)
                }
            }
            .sheet(item: $permissionsRequest) { request in
                SFTPPermissionsSheet(entries: request.entries, session: session) { outcome in
                    permissionsRequest = nil
                    report(outcome)
                }
            }
            .sheet(item: $batchSheet) { prompt in
                promptView(prompt)
            }
            .sheet(item: $infoEntry) { entry in
                infoSheet(entry, infoAttributes)
            }
            .confirmationDialog(
                "“\(conflictName)” already exists",
                isPresented: $isConflictPresented,
                titleVisibility: .visible
            ) {
                Button("Replace") { resolveConflicts(.replace) }
                Button("Keep Both") { resolveConflicts(.keepBoth) }
                Button("Skip") { resolveConflicts(.skip) }
                Button("Cancel", role: .cancel) {
                    pendingConflicts = []
                    pendingFreeDownloads = []
                }
            } message: {
                Text(conflictMessage)
            }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button {
                Task { await session.goBack() }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!session.canGoBack)
            .help("Back (⌘[)")
            .accessibilityLabel("Back")
            .keyboardShortcut("[", modifiers: .command)

            Button {
                Task { await session.goForward() }
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!session.canGoForward)
            .help("Forward (⌘])")
            .accessibilityLabel("Forward")
            .keyboardShortcut("]", modifiers: .command)

            Button {
                Task { await session.goUp() }
            } label: {
                Image(systemName: "arrow.up")
            }
            .disabled(!session.canGoUp)
            .help("Enclosing folder (⌘↑)")
            .accessibilityLabel("Enclosing folder")
            .keyboardShortcut(.upArrow, modifiers: .command)

            breadcrumbBar

            Button {
                Task { await session.load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(!session.isConnected || session.isLoading)
            .help("Reload (⌘R)")
            .accessibilityLabel("Reload")
            .keyboardShortcut("r", modifiers: .command)

            Button {
                showHidden.toggle()
            } label: {
                Image(systemName: showHidden ? "eye" : "eye.slash")
            }
            .help(showHidden ? "Hide hidden files (⇧⌘.)" : "Show hidden files (⇧⌘.)")
            .accessibilityLabel(showHidden ? "Hide hidden files" : "Show hidden files")
            .keyboardShortcut(".", modifiers: [.command, .shift])

            Button { download(nil) } label: {
                Image(systemName: "arrow.down.circle")
            }
            .help("Download the selected item (⌘D)")
            .accessibilityLabel("Download")
            .keyboardShortcut("d", modifiers: .command)
            .disabled(selection.isEmpty)

            Button { upload() } label: {
                Image(systemName: "arrow.up.circle")
            }
            .help("Upload files into this folder (⌘U)")
            .accessibilityLabel("Upload")
            .keyboardShortcut("u", modifiers: .command)
            .disabled(!session.isConnected)

            Button { beginNewFolder() } label: {
                Image(systemName: "folder.badge.plus")
            }
            .help("New Folder (⇧⌘N)")
            .accessibilityLabel("New Folder")
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(!session.isConnected)

            Button { confirmDelete(selectedEntries) } label: {
                Image(systemName: "trash")
            }
            .help("Delete the selection (⌘⌫)")
            .accessibilityLabel("Delete selection")
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(selection.isEmpty)

            Picker("View", selection: Binding(get: { viewMode }, set: { viewMode = $0 })) {
                ForEach(SFTPViewMode.allCases) { mode in
                    Image(systemName: mode.icon)
                        .accessibilityLabel(mode.label)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 76)
            .help("Switch between list and icon view")
            .accessibilityLabel("View mode")
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(.bar)
    }

    /// Finder's path bar: every component jumps to that level.
    private var breadcrumbBar: some View {
        HStack(spacing: 2) {
            ForEach(Array(session.breadcrumbs.enumerated()), id: \.offset) { index, crumb in
                if index > 0 {
                    Image(systemName: "chevron.compact.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                Button {
                    Task { await session.go(to: crumb.path) }
                } label: {
                    Text(crumb.name.isEmpty ? "/" : crumb.name)
                        .font(.callout)
                        .lineLimit(1)
                        .foregroundStyle(
                            index == session.breadcrumbs.count - 1 ? .primary : .secondary
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Go to \(crumb.path)")
            }
            Spacer(minLength: 4)
            Button {
                goToPath = session.path
                isGoToPresented = true
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
            .help("Go to Folder… (⌘G)")
            .accessibilityLabel("Go to Folder")
            .keyboardShortcut("g", modifiers: .command)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private var shortcutsSidebar: some View {
        List {
            Section("Places") {
                ForEach(session.shortcuts) { shortcut in
                    Button {
                        Task { await session.go(to: shortcut.path) }
                    } label: {
                        Label(shortcut.name, systemImage: shortcut.icon)
                            .font(.callout)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(shortcut.path)")
                }
            }
        }
        .listStyle(.sidebar)
        .frame(width: 160)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            if let progress = compressProgress {
                CompressProgressBanner(progress: progress)
            }
            if let message = session.errorMessage, !rows.isEmpty {
                errorBanner(message)
            }
            contentBody
        }
    }

    /// A message that stays above a usable listing: the server's reason for the
    /// folder it refused, without hiding the folder you are still in. The old
    /// inline version flashed and vanished because the successful reload cleared
    /// it one runloop later.
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button {
                session.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss the message")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var contentBody: some View {
        ZStack {
            if session.isConnecting || (session.isLoading && !session.isConnected) {
                connectingView
            } else if let message = session.errorMessage, rows.isEmpty {
                errorView(message)
            } else if session.isLoading && session.entries.isEmpty {
                ProgressView("Loading \(session.path)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                emptyView
            } else {
                switch viewMode {
                case .list: listView
                case .icons: iconView
                }
            }

            if session.isLoading && !session.entries.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Refreshing")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The rows both views draw.
    private var rows: [RemoteEntry] {
        session.rows(showHidden: showHidden, sortColumn: sortColumn, ascending: sortAscending)
    }

    private func sortBy(_ column: SFTPSortColumn) {
        if sortColumn == column {
            sortAscending.toggle()
        } else {
            sortColumn = column
            sortAscending = true
        }
    }

    private var listView: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(rows) { entry in
                        listRow(entry)
                        Divider().opacity(0.35)
                    }
                } header: {
                    listHeader
                }
            }
        }
    }

    private var listHeader: some View {
        HStack(spacing: 8) {
            ForEach(SFTPSortColumn.allCases) { column in
                Button {
                    sortBy(column)
                } label: {
                    HStack(spacing: 3) {
                        Text(column.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if sortColumn == column {
                            Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(
                        maxWidth: column.width == nil ? .infinity : nil,
                        alignment: column.alignment
                    )
                    .frame(width: column.width, alignment: column.alignment)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sort by \(column.title)")
                .accessibilityValue(
                    sortColumn == column ? (sortAscending ? "ascending" : "descending") : ""
                )
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func listRow(_ entry: RemoteEntry) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(nsImage: FileIcon.image(for: entry))
                    .resizable()
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(entry.isDirectory ? "—" : ByteFormatter.string(entry.size))
                .frame(width: SFTPSortColumn.size.width, alignment: .trailing)

            Text(DateFormatter.short.string(from: entry.modified ?? .distantPast))
                .frame(width: SFTPSortColumn.modified.width, alignment: .leading)

            Text(PermissionFormatter.string(entry.permissions))
                .font(.system(.caption, design: .monospaced))
                .frame(width: SFTPSortColumn.permissions.width, alignment: .leading)

            Text(entry.attributes.uid.map(String.init) ?? "—")
                .font(.system(.caption, design: .monospaced))
                .frame(width: SFTPSortColumn.owner.width, alignment: .leading)
        }
        .font(.callout)
        .monospacedDigit()
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(
            selection.contains(entry.path) ? Color.accentColor.opacity(0.20) : Color.clear
        )
        .contentShape(Rectangle())
        // One gesture recogniser, not two. A separate `onTapGesture` for the
        // single click swallows the double click on macOS, so a row could be
        // selected but never opened.
        // `onClick` reports the real event, so ⌘/⇧ are exact. A TapGesture
        // cannot carry modifiers, which is why multi-selection never worked.
        .onClick { clicks, flags in
            if clicks >= 2 { open(entry) } else { select(entry, flags: flags) }
        }
        .contextMenu { rowMenu(entry) }
        // Drag-out hands Finder a file promise, not a path string: a promise can
        // become a real file on drop, which a string cannot. The preview is the
        // row itself, so the drag image matches what is being dragged.
        .onDrag { promise(for: entry) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(entry))
        .accessibilityValue(selection.contains(entry.path) ? "selected" : "")
        .accessibilityAddTraits(selection.contains(entry.path) ? [.isSelected] : [])
        .accessibilityHint(entry.isDirectory ? "Double-click to open this folder" : "")
    }

    private var iconView: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 108), spacing: 12)],
                spacing: 14
            ) {
                ForEach(rows) { entry in
                    VStack(spacing: 5) {
                        Image(nsImage: FileIcon.image(for: entry, size: 48))
                            .resizable()
                            .frame(width: 48, height: 48)
                            .accessibilityHidden(true)
                        Text(entry.name)
                            .font(.caption)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .truncationMode(.middle)
                    }
                    .frame(width: 100, height: 84)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selection.contains(entry.path)
                                  ? Color.accentColor.opacity(0.22)
                                  : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onClick { clicks, flags in
                        if clicks >= 2 { open(entry) } else { select(entry, flags: flags) }
                    }
                    .contextMenu { rowMenu(entry) }
                    .onDrag { promise(for: entry) }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(accessibilityText(entry))
                    .accessibilityValue(selection.contains(entry.path) ? "selected" : "")
                    .accessibilityAddTraits(selection.contains(entry.path) ? [.isSelected] : [])
                    .accessibilityHint(entry.isDirectory ? "Double-click to open this folder" : "")
                }
            }
            .padding(16)
        }
    }

    private var connectingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Connecting to \(session.target)…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Signing in with the saved password or key. This gives up after 25 seconds.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button("Cancel") { session.cancelConnect() }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 34, weight: .thin))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text("Folder is empty")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The server's own words, with a Retry that rebuilds the transport.
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 460)
            HStack {
                Button("Retry") { Task { await session.reconnect() } }
                    .keyboardShortcut(.defaultAction)
                if session.isConnected {
                    Button("Go Home") { Task { await session.go(to: "~") } }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(session.isConnected ? Color.green : Color.red)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(session.isConnected ? "Connected" : "Disconnected")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(session.target)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer()
            selectionStatus
            Text("\(rows.count) of \(session.entries.count) items")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(rows.count) items shown")
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(.bar)
    }

    /// "3 of 12 selected · 4.2 MB · 1 folder" — the item count and total selected
    /// size the card asks the status bar to show. Folder sizes are not summed: that
    /// would be a tree walk on every click.
    @ViewBuilder
    private var selectionStatus: some View {
        let summary = session.selectionSummary(selection, rows: rows)
        if summary.count > 0 {
            Text(selectionText(summary))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel(selectionText(summary))
        }
    }

    /// Split out of the view builder: a `var` with appends inside an `@ViewBuilder`
    /// if-block pushes the type checker over its limit.
    private func selectionText(_ summary: (count: Int, bytes: UInt64, folders: Int)) -> String {
        var parts = ["\(summary.count) of \(rows.count) selected"]
        if summary.bytes > 0 { parts.append(ByteFormatter.string(summary.bytes)) }
        if summary.folders > 0 {
            parts.append(summary.folders == 1 ? "1 folder" : "\(summary.folders) folders")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Prompts

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var deleteTitle: String {
        if deleteTarget.count == 1, let only = deleteTarget.first {
            return "Delete “\(only.name)”?"
        }
        return "Delete \(deleteTarget.count) items?"
    }

    /// Names what the delete takes with it. For a folder the count is the server's,
    /// so the sentence states a real number rather than "all contents" — the card
    /// requires the recursive item count.
    private var deleteMessage: String {
        guard deleteTarget.count == 1, let only = deleteTarget.first, only.isDirectory,
              let total = deleteItemCount else {
            return "This is permanent: SFTP has no Trash."
        }
        // `total` counts the folder itself, so the contents are total - 1.
        let contents = max(0, total - 1)
        let listing = contents == 0
            ? "It is empty."
            : "It contains \(contents) item\(contents == 1 ? "" : "s"), which are deleted too."
        return "\(listing) This is permanent: SFTP has no Trash."
    }

    /// The conflict dialog's second line: what each answer does, and how many other
    /// items the answer covers.
    private var conflictMessage: String {
        let directory = conflictDirectory?.path ?? "that folder"
        let others = pendingConflicts.count - 1
        var lines = ["There is already an item named “\(conflictName)” in \(directory)."]
        if others > 0 {
            lines.append("This answer applies to the other \(others) conflicting item\(others == 1 ? "" : "s") too.")
        }
        lines.append("Replace overwrites it, Keep Both saves this copy under a new name, Skip leaves it alone.")
        return lines.joined(separator: "\n")
    }

    private func beginNewFolder() {
        newFolderName = "untitled folder"
        isNewFolderPresented = true
    }

    private func beginRename(_ entry: RemoteEntry) {
        renameDraft = entry.name
        renameTarget = entry
    }

    /// Get Info: a sheet with the server's own `stat` values for one entry.
    private func showInfo(_ entry: RemoteEntry) {
        infoEntry = entry
        infoAttributes = entry.attributes
        Task {
            guard let attributes = await session.info(for: entry) else { return }
            // Only apply if the sheet is still about the same row.
            if infoEntry?.id == entry.id { infoAttributes = attributes }
        }
    }

    private func confirmDelete(_ entries: [RemoteEntry]) {
        deleteTarget = entries
        deleteItemCount = nil
        isDeletePresented = true
        // Count before the dialog is read, so a folder's sentence names the real
        // number of entries the server would remove.
        guard entries.count == 1, let only = entries.first, only.isDirectory, !only.isSymlink else {
            return
        }
        Task { deleteItemCount = await session.deleteCount(for: only) }
    }

    // MARK: - Actions

    /// Picking a row, with Finder's modifiers: ⌘ toggles, ⇧ extends the range from
    /// the anchor, a plain click replaces.
    ///
    /// The rules themselves are `SFTPSelection` in the core, so the list view, the
    /// icon view and the tests all share one implementation.
    private func select(_ entry: RemoteEntry, flags: NSEvent.ModifierFlags) {
        let mode: SFTPSelectionMode
        if flags.contains(.command) {
            mode = .toggle
        } else if flags.contains(.shift) {
            mode = .extend
        } else {
            mode = .replace
        }
        selection = SFTPSelection.apply(
            mode,
            to: selection,
            anchor: &selectionAnchor,
            path: entry.path,
            order: rows.map(\.path)
        )
        session.selectedPath = selection.count == 1 ? selection.first : nil
    }

    private func clearSelection() {
        guard !selection.isEmpty else { return }
        selection = []
        selectionAnchor = nil
        session.selectedPath = nil
    }

    private func openSelection() {
        // ⌘↓ on a file downloads it, on a folder opens it — same rule as a
        // double-click, so the two shortcuts never disagree.
        if let entry = selectedEntries.first, selectedEntries.count == 1 {
            open(entry)
        }
    }

    /// Return on a single selected row — Finder's rename. A multi-selection has no
    /// one name to edit, so it does nothing rather than guessing.
    private func renameSelection() {
        guard selectedEntries.count == 1, let only = selectedEntries.first else { return }
        beginRename(only)
    }

    private func open(_ entry: RemoteEntry) {
        session.selectedPath = entry.path
        if entry.isDirectory {
            Task { await session.open(entry) }
        } else {
            // Double-clicking a file downloads it: there is no local app to hand a
            // remote path to, and the card asks for double-click to act on files.
            download([entry])
        }
    }

    /// Drag-out: an item provider whose bytes are fetched only if the item is
    /// actually dropped, into the temporary staging area AppKit copies from.
    private func promise(for entry: RemoteEntry) -> NSItemProvider {
        SFTPFilePromise.provider(for: entry, session: session)
    }

    private func accessibilityText(_ entry: RemoteEntry) -> String {
        let kind = entry.isDirectory ? "Folder" : "File"
        let size = entry.isDirectory ? "" : ", \(ByteFormatter.string(entry.size))"
        let date = entry.modified.map { ", modified \(DateFormatter.short.string(from: $0))" } ?? ""
        return "\(kind) \(entry.name)\(size)\(date)"
    }

    @ViewBuilder
    private func rowMenu(_ entry: RemoteEntry) -> some View {
        // Right-clicking a row outside the selection acts on that row alone, as
        // Finder does — otherwise "Delete" would act on something invisible.
        let targets = selection.contains(entry.path) ? selectedEntries : [entry]
        let many = targets.count > 1

        if entry.isDirectory {
            Button("Open") { open(entry) }
        }
        Button(many ? "Download \(targets.count) Items…" : "Download…") { download(targets) }
        Button(many ? "Compress and Download \(targets.count) Items…" : "Compress and Download…") {
            compressAndDownload(targets)
        }
        Divider()
        Button("Rename…") { beginRename(entry) }
            .disabled(many)
        Button(many ? "Delete \(targets.count) Items…" : "Delete…", role: .destructive) {
            confirmDelete(targets)
        }
        Button("Show Info") { showInfo(entry) }
            .disabled(many)
        Button(many ? "Permissions for \(targets.count) Items…" : "Permissions…") {
            if many {
                permissionsRequest = PermissionsRequest(entries: targets)
            } else {
                permissionsTarget = entry
            }
        }
        Divider()
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.path, forType: .string)
        }
    }

    /// The rows the current selection names.
    private var selectedEntries: [RemoteEntry] {
        rows.filter { selection.contains($0.path) }
    }

    /// Downloads the selection, or an explicit set supplied by a row menu.
    ///
    /// One file gets a save panel; a folder tree or several items get a
    /// destination folder. An existing local name is never silently overwritten.
    /// Compresses the selection on the server and streams the archive down.
    ///
    /// Server-side on purpose: only the compressed bytes cross the network, and
    /// nothing is written to this Mac's disk but the final file.
    private func compressAndDownload(_ entries: [RemoteEntry]) {
        guard !entries.isEmpty else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = RemoteCompress.suggestedName(for: entries)
        panel.canCreateDirectories = true
        panel.title = entries.count == 1
            ? "Compress and Download \(entries[0].name)"
            : "Compress and Download \(entries.count) Items"
        panel.prompt = "Download"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        compressProgress = CompressProgress(name: destination.lastPathComponent, bytes: 0)
        let shell = session.makeShell()
        Task {
            do {
                try await RemoteCompress.run(
                    entries: entries,
                    shell: shell,
                    destination: destination,
                    progress: { received, _ in
                        Task { @MainActor in
                            compressProgress?.bytes = received
                        }
                    }
                )
                await MainActor.run { compressProgress = nil }
            } catch {
                await MainActor.run {
                    compressProgress = nil
                    session.errorMessage = (error as? LocalizedError)?.errorDescription
                        ?? String(describing: error)
                }
            }
        }
    }

    private func download(_ explicit: [RemoteEntry]?) {
        let entries = explicit ?? selectedEntries
        guard !entries.isEmpty else { return }

        if entries.count == 1, let entry = entries.first, !entry.isDirectory {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = entry.name
            panel.canCreateDirectories = true
            panel.title = "Download \(entry.name)"
            panel.prompt = "Download"
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            session.enqueueDownload([(entry: entry, destination: destination)])
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Download Here"
        panel.message = entries.count == 1
            ? "Choose where to save \(entries.first?.name ?? "the folder")"
            : "Choose where to save \(entries.count) items"
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        // Never overwrite silently: names that already exist are held back and the
        // user answers once — Replace, Keep Both (Finder numbering) or Skip — and
        // the answer covers every conflicting item in this batch.
        var free: [(entry: RemoteEntry, destination: URL)] = []
        var conflicts: [(entry: RemoteEntry, destination: URL)] = []
        for entry in entries {
            let target = directory.appendingPathComponent(entry.name)
            if FileManager.default.fileExists(atPath: target.path) {
                conflicts.append((entry, target))
            } else {
                free.append((entry, target))
            }
        }
        pendingFreeDownloads = free
        guard let first = conflicts.first else {
            pendingFreeDownloads = []
            session.enqueueDownload(free)
            return
        }
        pendingConflicts = conflicts
        conflictName = first.entry.name
        conflictDirectory = directory
        isConflictPresented = true
    }

    /// Applies the conflict answer to the whole batch, then enqueues it.
    private func resolveConflicts(_ resolution: ConflictResolution) {
        let conflicts = pendingConflicts
        let free = pendingFreeDownloads
        pendingConflicts = []
        pendingFreeDownloads = []
        guard !conflicts.isEmpty else { return }

        switch resolution {
        case .skip:
            // Reported, not silently dropped: a file the user asked for and did
            // not get must be visible in one summary.
            var outcome = BatchOutcome()
            outcome.skipped = conflicts.map(\.entry.name) + free.map(\.entry.name)
            if !free.isEmpty { session.enqueueDownload(free) }
            report(outcome)
        case .replace:
            session.enqueueDownload(free + conflicts)
        case .keepBoth:
            var resolved = free
            var taken = Set(free.map { $0.destination.lastPathComponent })
            for conflict in conflicts {
                let folder = conflict.destination.deletingLastPathComponent()
                let onDisk = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                taken.formUnion(onDisk)
                let name = ConflictResolver.keepBothName(for: conflict.entry.name, existing: taken)
                taken.insert(name)
                resolved.append((conflict.entry, folder.appendingPathComponent(name)))
            }
            session.enqueueDownload(resolved)
        }
    }

    private func upload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.message = "Choose files or folders to upload into \(session.path)"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        session.enqueueUpload(panel.urls)
    }

    private var goToSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Go to Folder").font(.headline)
            TextField("/path/to/folder", text: $goToPath)
                .textFieldStyle(.roundedBorder)
                .frame(width: 380)
                .accessibilityLabel("Folder path")
                .onSubmit(performGoTo)
            Text("Relative paths start at \(session.path)")
                .font(.caption)
                .foregroundStyle(.tertiary)
            HStack {
                Spacer()
                Button("Cancel") { isGoToPresented = false }
                Button("Go", action: performGoTo)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }

    private func performGoTo() {
        let destination = goToPath
        isGoToPresented = false
        Task { await session.go(to: destination) }
    }

    // MARK: - Reporting

    /// One place that decides how a batch is reported: silence when everything
    /// worked, one summary when part of it did not, one failure sheet for a single
    /// item. Never one modal per item.
    private func report(_ outcome: BatchOutcome) {
        guard !outcome.isEmpty else { return }
        if outcome.isCompleteSuccess { return }
        if outcome.failedNames.count == 1, outcome.succeeded.isEmpty, outcome.skipped.isEmpty,
           let failure = outcome.failures.first {
            batchSheet = .failure(OperationError(name: failure.name, error: ServerMessage(failure.reason)))
            return
        }
        batchSheet = .summary(outcome)
    }

    /// Get Info: the server's own `stat` values, not the listing's snapshot — a
    /// sheet that quotes a permissions value the row has since outgrown is worse
    /// than no sheet. `info()` fills this in a moment after it opens.
    private func infoSheet(_ entry: RemoteEntry, _ attributes: SFTPAttributes?) -> some View {
        let values = attributes ?? entry.attributes
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(nsImage: FileIcon.image(for: entry, size: 32))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.headline)
                        .textSelection(.enabled)
                    Text(entry.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Divider()
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                infoRow("Kind", infoKind(entry))
                infoRow("Size", ByteFormatter.string(values.size))
                infoRow("Permissions", "\\(PermissionFormatter.string(values.permissions))  \\(PermissionSet(modeBits: UInt16((values.permissions ?? 0) & 0o7777)).octal)")
                infoRow("Owner", values.uid.map(String.init) ?? "—")
                infoRow("Group", values.gid.map(String.init) ?? "—")
                infoRow("Modified", values.modified.map { DateFormatter.short.string(from: $0) } ?? "—")
                infoRow("Accessed", values.accessed.map { DateFormatter.short.string(from: $0) } ?? "—")
            }
            .font(.callout)
            HStack {
                Button("Permissions…") {
                    infoEntry = nil
                    permissionsTarget = entry
                }
                .disabled(entry.isSymlink)
                Spacer()
                Button("OK") { infoEntry = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 420)
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func infoKind(_ entry: RemoteEntry) -> String {
        if entry.isSymlink { return "Symbolic link" }
        return entry.isDirectory ? "Folder" : "File"
    }

    @ViewBuilder
    private func promptView(_ prompt: BatchPrompt) -> some View {
        switch prompt {
        case .summary(let outcome):
            batchSummarySheet(outcome)
        case .failure(let error):
            failureSheet(error)
        }
    }

    /// The one summary a partially completed batch shows, with the exact list of
    /// what worked and what did not.
    private func batchSummarySheet(_ outcome: BatchOutcome) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: outcome.failures.isEmpty
                      ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(outcome.failures.isEmpty ? .green : .orange)
                    .font(.title2)
                    .accessibilityHidden(true)
                Text(outcome.headline).font(.headline)
            }
            ScrollView {
                Text(outcome.detail)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            HStack {
                Spacer()
                Button("OK") { batchSheet = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 500)
    }

    /// One failure, worded with whether elevation was tried — never a dead end.
    private func failureSheet(_ failure: OperationError) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: OperationFailureText.isPermissionDenied(failure.error)
                      ? "lock.trianglebadge.exclamationmark" : "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.title2)
                    .accessibilityHidden(true)
                Text(OperationFailureText.title(for: failure.error, subject: failure.name))
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(OperationFailureText.message(for: failure.error, context: session.elevationContext))
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("OK") { batchSheet = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 480)
    }
}

/// One modal that needs the user's answer. `Identifiable` so it can drive a single
/// `sheet(item:)`: two summaries can never race for one presentation slot.
enum BatchPrompt: Identifiable {
    case summary(BatchOutcome)
    case failure(OperationError)

    var id: String {
        switch self {
        case .summary(let outcome):
            return "summary-\(outcome.headline)-\(outcome.succeeded.count)-\(outcome.failures.count)"
        case .failure(let error):
            return "failure-\(error.id)"
        }
    }
}

/// One or many entries whose permissions the sheet edits. `Identifiable` so it can
/// drive `sheet(item:)`.
struct PermissionsRequest: Identifiable {
    let entries: [RemoteEntry]
    var id: String { entries.map(\.id).joined(separator: "|") }
}

/// Carries a batch failure's already-formatted reason into the single-failure
/// sheet, so the server's words are shown without re-deriving a typed error.
struct ServerMessage: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}

// MARK: - Formatting helpers

enum ByteFormatter {
    static func string(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

enum PermissionFormatter {
    /// `0o100644` → `-rw-r--r--`, the way Finder's Get Info shows it.
    static func string(_ mode: UInt32?) -> String {
        guard let mode else { return "—" }
        var result = String(typeCharacter(mode))
        let bits: [(UInt32, Character)] = [
            (0o400, "r"), (0o200, "w"), (0o100, "x"),
            (0o040, "r"), (0o020, "w"), (0o010, "x"),
            (0o004, "r"), (0o002, "w"), (0o001, "x"),
        ]
        for (mask, character) in bits {
            result.append(mode & mask != 0 ? character : "-")
        }
        return result
    }

    private static func typeCharacter(_ mode: UInt32) -> Character {
        switch mode & 0o170000 {
        case 0o040000: return "d"
        case 0o120000: return "l"
        case 0o140000: return "s"
        case 0o010000: return "p"
        case 0o060000: return "b"
        case 0o020000: return "c"
        default: return "-"
        }
    }
}

enum FileIcon {
    /// The real AppKit icon for the entry's kind, so the window looks like Finder
    /// rather than a wall of identical glyphs.
    static func image(for entry: RemoteEntry, size: CGFloat = 16) -> NSImage {
        if entry.isDirectory {
            if let folder = NSImage(named: "NSFolder") { return resized(folder, to: size) }
        } else if entry.isSymlink {
            if let alias = NSImage(named: "NSAliasBadgeIcon") { return resized(alias, to: size) }
        } else {
            let ext = (entry.name as NSString).pathExtension
            if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
                return resized(NSWorkspace.shared.icon(for: type), to: size)
            }
            if let generic = NSImage(named: "NSGenericDocument") {
                return resized(generic, to: size)
            }
        }
        return resized(NSWorkspace.shared.icon(for: .data), to: size)
    }

    private static func resized(_ image: NSImage, to size: CGFloat) -> NSImage {
        let copy = image.copy() as? NSImage ?? image
        copy.size = NSSize(width: size, height: size)
        return copy
    }
}

enum DateFormatter {
    static let short: Foundation.DateFormatter = {
        let formatter = Foundation.DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}
