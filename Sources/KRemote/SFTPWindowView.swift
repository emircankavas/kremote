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

    @State private var selection: String?
    @State private var sortColumn: SFTPSortColumn = .name
    @State private var sortAscending = true
    @State private var goToPath = ""
    @State private var isGoToPresented = false

    private var viewMode: SFTPViewMode {
        get { SFTPViewMode(rawValue: viewModeRaw) ?? .list }
        nonmutating set { viewModeRaw = newValue.rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                shortcutsSidebar
                Divider()
                content
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 780, minHeight: 440)
        .navigationTitle(session.title)
        .task { await session.connect() }
        .background(
            // Return and Enter open the selected folder. A hidden button is the
            // only way to bind a bare key to an action in SwiftUI.
            Group {
                Button("") { openSelection() }
                    .keyboardShortcut(.return, modifiers: [])
                Button("") { openSelection() }
                    .keyboardShortcut(.defaultAction)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        )
        .onChange(of: session.path) { _, _ in selection = nil }
        .sheet(isPresented: $isGoToPresented) { goToSheet }
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
        ZStack {
            if session.isConnecting || (session.isLoading && !session.isConnected) {
                connectingView
            } else if let message = session.errorMessage {
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
            selection == entry.path ? Color.accentColor.opacity(0.20) : Color.clear
        )
        .contentShape(Rectangle())
        // One gesture recogniser, not two. A separate `onTapGesture` for the
        // single click swallows the double click on macOS, so a row could be
        // selected but never opened.
        .gesture(
            TapGesture(count: 2).onEnded { open(entry) }
                .exclusively(before: TapGesture().onEnded { select(entry) })
        )
        .contextMenu { rowMenu(entry) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(entry))
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
                            .fill(selection == entry.path
                                  ? Color.accentColor.opacity(0.22)
                                  : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .gesture(
                        TapGesture(count: 2).onEnded { open(entry) }
                            .exclusively(before: TapGesture().onEnded { select(entry) })
                    )
                    .contextMenu { rowMenu(entry) }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(accessibilityText(entry))
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
            Text("\(rows.count) of \(session.entries.count) items")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(rows.count) items shown")
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(.bar)
    }

    // MARK: - Actions

    /// Picking a row: selection is shared with the session so Return knows what
    /// is highlighted.
    private func select(_ entry: RemoteEntry) {
        selection = entry.path
        session.selectedPath = entry.path
    }

    private func openSelection() {
        Task { await session.openSelection() }
    }

    private func open(_ entry: RemoteEntry) {
        session.selectedPath = entry.path
        // A folder navigates; a file is card 5's job (open/download).
        guard entry.isDirectory else { return }
        Task { await session.open(entry) }
    }

    private func accessibilityText(_ entry: RemoteEntry) -> String {
        let kind = entry.isDirectory ? "Folder" : "File"
        let size = entry.isDirectory ? "" : ", \(ByteFormatter.string(entry.size))"
        let date = entry.modified.map { ", modified \(DateFormatter.short.string(from: $0))" } ?? ""
        return "\(kind) \(entry.name)\(size)\(date)"
    }

    @ViewBuilder
    private func rowMenu(_ entry: RemoteEntry) -> some View {
        if entry.isDirectory {
            Button("Open") { open(entry) }
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.path, forType: .string)
        }
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
