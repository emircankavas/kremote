import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KRemoteCore

/// How the browser draws a directory. Persisted app-wide, not per connection.
enum SFTPViewMode: String, CaseIterable {
    case list
    case icons

    var icon: String { self == .list ? "list.bullet" : "square.grid.2x2" }
    var label: String { self == .list ? "List" : "Icons" }
}

/// A Finder-like file browser for one connection.
struct SFTPWindowView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: SFTPSession
    @AppStorage("sftpViewMode") private var viewModeRaw = SFTPViewMode.list.rawValue
    @AppStorage("sftpShowHidden") private var showHidden = false

    @State private var selection: String?
    @State private var sortColumn: SortColumn = .name
    @State private var sortAscending = true
    @State private var goToPath = ""
    @State private var isGoToPresented = false
    @State private var isDropTargeted = false

    private var viewMode: SFTPViewMode {
        get { SFTPViewMode(rawValue: viewModeRaw) ?? .list }
        nonmutating set { viewModeRaw = newValue.rawValue }
    }

    enum SortColumn: String { case name, size, modified, permissions }

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
        .frame(minWidth: 720, minHeight: 420)
        .navigationTitle(session.title)
        .task { await session.connect() }
        .onDisappear { session.disconnect() }
        .sheet(isPresented: $isGoToPresented) { goToSheet }
        .background(
            // Dropping files uploads them into the directory being shown.
            Color.clear
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                    handleDrop(providers)
                }
        )
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { session.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!session.canGoBack)
                .help("Back (⌘[)")
                .keyboardShortcut("[", modifiers: .command)

            Button { session.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!session.canGoForward)
                .help("Forward (⌘])")
                .keyboardShortcut("]", modifiers: .command)

            Button { session.goUp() } label: { Image(systemName: "arrow.up") }
                .disabled(!session.canGoUp)
                .help("Enclosing folder (⌘↑)")
                .keyboardShortcut(.upArrow, modifiers: .command)

            breadcrumbBar

            Button { Task { await session.reload() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(!session.isConnected || session.isLoading)
            .help("Reload (⌘R)")
            .keyboardShortcut("r", modifiers: .command)

            Picker("View", selection: Binding(get: { viewMode }, set: { viewMode = $0 })) {
                ForEach(SFTPViewMode.allCases, id: \.self) { mode in
                    Image(systemName: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 76)
            .help("Switch between list and icon view")
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(.bar)
    }

    /// Finder's path bar: every component is clickable, plus a folder menu on the
    /// last one for jumping sideways.
    private var breadcrumbBar: some View {
        HStack(spacing: 2) {
            ForEach(Array(session.breadcrumbs.enumerated()), id: \.offset) { index, crumb in
                if index > 0 {
                    Image(systemName: "chevron.compact.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Button {
                    session.go(to: crumb.path)
                } label: {
                    Text(crumb.name)
                        .font(.callout)
                        .lineLimit(1)
                        .foregroundStyle(index == session.breadcrumbs.count - 1 ? .primary : .secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .trailing) {
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
            .keyboardShortcut("g", modifiers: .command)
        }
    }

    private var shortcutsSidebar: some View {
        List {
            Section("Places") {
                ForEach(session.shortcuts, id: \.path) { shortcut in
                    Button {
                        session.go(to: shortcut.path)
                    } label: {
                        Label(shortcut.name, systemImage: shortcut.icon)
                            .font(.callout)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.sidebar)
        .frame(width: 150)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        ZStack {
            if let message = session.errorMessage {
                errorView(message)
            } else if session.entries.isEmpty && session.isLoading {
                ProgressView("Loading \(session.path)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.entries.isEmpty {
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
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(4)
            }
        }
    }

    private var visibleEntries: [RemoteEntry] {
        var list = session.entries
        if !showHidden {
            list = list.filter { !$0.name.hasPrefix(".") }
        }
        return list.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let result: ComparisonResult
            switch sortColumn {
            case .name:
                result = a.name.localizedStandardCompare(b.name)
            case .size:
                result = (a.size ?? 0) == (b.size ?? 0)
                    ? a.name.localizedStandardCompare(b.name)
                    : ((a.size ?? 0) < (b.size ?? 0) ? .orderedAscending : .orderedDescending)
            case .modified:
                result = (a.modified ?? .distantPast) == (b.modified ?? .distantPast)
                    ? a.name.localizedStandardCompare(b.name)
                    : ((a.modified ?? .distantPast) < (b.modified ?? .distantPast) ? .orderedAscending : .orderedDescending)
            case .permissions:
                result = (a.permissions ?? 0) == (b.permissions ?? 0)
                    ? a.name.localizedStandardCompare(b.name)
                    : ((a.permissions ?? 0) < (b.permissions ?? 0) ? .orderedAscending : .orderedDescending)
            }
            return sortAscending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private var listView: some View {
        Table(visibleEntries, selection: $selection) {
            TableColumn("Name") { entry in
                HStack(spacing: 6) {
                    Image(nsImage: FileIcon.image(for: entry))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(entry.name)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { open(entry) }
                .contextMenu { rowMenu(entry) }
            }
            .width(min: 180, ideal: 320)

            TableColumn("Size") { entry in
                Text(entry.isDirectory ? "—" : ByteFormatter.string(entry.size))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(80)

            TableColumn("Modified") { entry in
                Text(DateFormatter.short.string(from: entry.modified ?? .distantPast))
                    .foregroundStyle(.secondary)
            }
            .width(130)

            TableColumn("Permissions") { entry in
                Text(PermissionFormatter.string(entry.permissions))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(100)

            TableColumn("Owner") { entry in
                Text(entry.attributes.uid.map { "\($0)" } ?? "—")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(60)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    private var iconView: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 108), spacing: 12)],
                spacing: 14
            ) {
                ForEach(visibleEntries) { entry in
                    VStack(spacing: 5) {
                        Image(nsImage: FileIcon.image(for: entry, size: 48))
                            .resizable()
                            .frame(width: 48, height: 48)
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
                    .onTapGesture { selection = entry.path }
                    .onTapGesture(count: 2) { open(entry) }
                    .contextMenu { rowMenu(entry) }
                }
            }
            .padding(16)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 34, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("Folder is empty")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 420)
            HStack {
                Button("Retry") { Task { await session.reconnect() } }
                Button("Go Home") { session.go(to: "~") }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(session.isConnected ? Color.green : Color.red)
                .frame(width: 7, height: 7)
            Text(session.isConnected ? "Connected" : "Disconnected")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(session.target)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer()
            Text("\(visibleEntries.count) items")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(.bar)
    }

    // MARK: - Actions

    private func open(_ entry: RemoteEntry) {
        if entry.isDirectory {
            session.enter(entry)
        }
    }

    @ViewBuilder
    private func rowMenu(_ entry: RemoteEntry) -> some View {
        if entry.isDirectory {
            Button("Open") { session.enter(entry) }
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
                .frame(width: 360)
                .onSubmit {
                    session.go(to: goToPath)
                    isGoToPresented = false
                }
            HStack {
                Spacer()
                Button("Cancel") { isGoToPresented = false }
                Button("Go") {
                    session.go(to: goToPath)
                    isGoToPresented = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        // Transfers land in card 5; accept the drop so the gesture is not a
        // silent no-op, and say so plainly rather than pretending it worked.
        session.errorMessage = "Uploading by drag and drop is not available in this build yet."
        return true
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
        default: return "-"
        }
    }
}

enum FileIcon {
    /// The real AppKit icon for the entry's kind, so the window looks like Finder
    /// rather than a wall of identical glyphs.
    static func image(for entry: RemoteEntry, size: CGFloat = 16) -> NSImage {
        let name: String
        if entry.isDirectory {
            name = "NSFolder"
        } else if entry.isSymlink {
            name = "NSAliasBadgeIcon"
        } else {
            let ext = (entry.name as NSString).pathExtension
            if !ext.isEmpty,
               let type = UTType(filenameExtension: ext),
               let icon = NSWorkspace.shared.icon(for: type) as NSImage? {
                return resized(icon, to: size)
            }
            name = "NSGenericDocument"
        }
        if let image = NSImage(named: name) {
            return resized(image, to: size)
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
