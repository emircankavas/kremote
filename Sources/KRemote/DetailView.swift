import SwiftUI
import KRemoteCore

/// Right-hand side: the tab strip and the terminal area. The terminal area is one
/// pane, or a 2–4 pane split.
///
/// Every session view is kept mounted for the whole lifetime of the session, keyed
/// by a stable identity. Switching which session a pane shows therefore only
/// changes visibility — it never tears down and rebuilds a terminal, which would
/// otherwise leave a view attached to the previous session's ssh process.
struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.sessions.isEmpty {
            PlaceholderView()
        } else {
            VStack(spacing: 0) {
                TabStrip()
                Divider()
                TerminalArea()
            }
        }
    }
}

// MARK: - Tab strip (with the session toolbar on the right)

private struct TabStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(model.sessions) { session in
                        TabButton(session: session, isActive: session.id == model.activeSessionID) {
                            model.activateTab(session.id)
                        } onClose: {
                            model.closeSession(session.id)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            Divider().frame(height: 22)
            toolbar
        }
        .frame(height: 34)
        .background(.bar)
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button {
                model.requestRoot()
            } label: {
                Image(systemName: "number")
            }
            .help("Become root on the focused session (runs sudo -i)")
            .disabled(model.focusedSession == nil)

            Button {
                model.setSplit(!model.splitMode, panes: model.splitMode ? nil : 2)
            } label: {
                Image(systemName: "square.split.2x1")
            }
            .help(model.splitMode ? "Exit split view" : "Split into two panes")
            .disabled(model.sessions.count < 2 && !model.splitMode)

            if model.splitMode {
                ForEach(2...PaneLayout.maximum, id: \.self) { count in
                    Button("\(count)") { model.setPaneCount(count) }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .tint(count == model.tiles.count ? .accentColor : Color(nsColor: .controlColor))
                }
            }
        }
        .padding(.horizontal, 8)
    }
}

private struct TabButton: View {
    let session: Session
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.caption)
            Text(session.displayTitle)
                .lineLimit(1)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .opacity(isHovering || isActive ? 1 : 0)
            .help("Close tab")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor.opacity(0.22) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Terminal area

private struct TerminalArea: View {
    @Environment(AppModel.self) private var model

    private let gap: CGFloat = 1

    var body: some View {
        GeometryReader { geometry in
            let layout = model.paneLayout
            let columns = layout.columns
            let rows = layout.rows
            let cellWidth = (geometry.size.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
            let cellHeight = (geometry.size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)

            ZStack(alignment: .topLeading) {
                // Every session stays mounted for its whole life; only the ones in
                // a pane are placed in a cell and shown. The rest are parked
                // off-screen at 1x1 so their ssh process is untouched.
                ForEach(model.sessions) { session in
                    SessionContent(
                        session: session,
                        isFocused: focused(session),
                        showPaneChrome: model.splitMode,
                        onFocus: { model.focus(session.id) }
                    )
                    .frame(
                        width: cellWidth(for: session, cellWidth: cellWidth),
                        height: cellHeight(for: session, cellHeight: cellHeight)
                    )
                    .offset(offset(for: session, cellWidth: cellWidth, cellHeight: cellHeight, columns: columns))
                    .opacity(isVisible(session) ? 1 : 0)
                    .allowsHitTesting(isVisible(session))
                }

                // Empty panes sit on top of the parked views.
                if model.splitMode {
                    ForEach(emptyTileIndices, id: \.self) { index in
                        EmptyPaneView(tileIndex: index)
                            .frame(width: cellWidth, height: cellHeight)
                            .offset(cellOffset(index, cellWidth: cellWidth, cellHeight: cellHeight, columns: columns))
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Placement

    /// Tile index of `session` when it is currently shown in a pane.
    private func visibleTileIndex(of session: Session) -> Int? {
        if model.splitMode {
            return model.tileIndex(of: session.id)
        }
        return session.id == model.activeSessionID ? 0 : nil
    }

    private func isVisible(_ session: Session) -> Bool {
        visibleTileIndex(of: session) != nil
    }

    private func cellWidth(for session: Session, cellWidth: CGFloat) -> CGFloat {
        isVisible(session) ? cellWidth : 1
    }

    private func cellHeight(for session: Session, cellHeight: CGFloat) -> CGFloat {
        isVisible(session) ? cellHeight : 1
    }

    private func offset(for session: Session, cellWidth: CGFloat, cellHeight: CGFloat, columns: Int) -> CGSize {
        guard let index = visibleTileIndex(of: session) else {
            return CGSize(width: -10_000, height: -10_000) // parked off-screen, still alive
        }
        return cellOffset(index, cellWidth: cellWidth, cellHeight: cellHeight, columns: columns)
    }

    private func cellOffset(_ index: Int, cellWidth: CGFloat, cellHeight: CGFloat, columns: Int) -> CGSize {
        let column = index % columns
        let row = index / columns
        return CGSize(
            width: CGFloat(column) * (cellWidth + gap),
            height: CGFloat(row) * (cellHeight + gap)
        )
    }

    private var emptyTileIndices: [Int] {
        model.tiles.indices.filter { model.tiles[$0] == nil }
    }

    private func focused(_ session: Session) -> Bool {
        guard model.splitMode else { return true }
        return model.tiles.indices.contains(model.focusedTile) && model.tiles[model.focusedTile] == session.id
    }
}

/// A pane with no session yet; lets the user drop a session into it.
private struct EmptyPaneView: View {
    @Environment(AppModel.self) private var model
    let tileIndex: Int

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Empty pane")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !model.sessions.isEmpty {
                Menu("Show…") {
                    ForEach(model.sessions) { candidate in
                        Button(candidate.displayTitle) { model.assign(candidate.id, toTile: tileIndex) }
                    }
                }
                .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .contentShape(Rectangle())
        .onTapGesture { model.focusTile(tileIndex) }
    }
}

/// A live terminal for one session, including status and reconnect.
private struct SessionContent: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let isVisible: Bool
    let isFocused: Bool
    let showPaneChrome: Bool
    let onFocus: () -> Void

    @State private var state: SSHPtySession.State = .idle

    var body: some View {
        VStack(spacing: 0) {
            if showPaneChrome { paneHeader }
            statusBar
            Divider()
            terminal
        }
        .background(.background)
        .overlay(
            Rectangle().strokeBorder(
                isFocused && showPaneChrome ? Color.accentColor : Color.clear,
                lineWidth: 2
            )
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onFocus)
    }

    @ViewBuilder
    private var terminal: some View {
        if let node = model.find(session.nodeID), node.supportsSSH {
            let effective = model.effective(node.id)
            TerminalSessionView(
                host: effective?.host ?? "",
                port: effective?.port ?? 22,
                username: effective?.username ?? "",
                password: effective?.password ?? "",
                identityFile: effective?.identityFile ?? "",
                remoteCommand: effective?.remoteCommand ?? "",
                inputRequests: isFocused ? model.rootRequest : 0,
                pendingCommand: rootCommand(for: effective),
                pendingPassword: effective?.password ?? "",
                onStateChange: { newState in
                    guard model.currentGeneration(of: session.id) == session.generation else { return }
                    state = newState
                    if case .disconnected(let reason) = newState, reason == nil {
                        model.closeSession(session.id)
                    }
                },
                onTitleChange: { model.updateTitle(session.id, title: $0) },
                onFocus: onFocus
            )
            .id(session.generation)
        } else if let node = model.find(session.nodeID) {
            UnsupportedProtocolView(name: node.name, protocolName: model.effective(node.id)?.protocolName ?? "")
        } else {
            Text("Connection no longer exists.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// `sudo -S -i` reads the password from stdin, so the coordinator can send the
    /// stored one; plain `sudo -i` would prompt on the terminal instead.
    private func rootCommand(for effective: EffectiveConnection?) -> String {
        (effective?.password.isEmpty ?? true) ? "sudo -i" : "sudo -S -i"
    }

    private var paneHeader: some View {
        HStack(spacing: 6) {
            Menu(session.displayTitle) {
                ForEach(model.sessions) { candidate in
                    Button(candidate.displayTitle) { model.assign(candidate.id, toTileShowing: session.id) }
                }
            }
            .menuStyle(.borderlessButton)
            .font(.caption)
            .fixedSize()
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(isFocused ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
    }

    private var statusBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if let node = model.find(session.nodeID) {
                Text(model.effective(node.id)?.summary ?? "")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if isDisconnected {
                Button("Reconnect") { model.reconnect(session.id) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(.bar)
    }

    private var isDisconnected: Bool {
        if case .disconnected = state { return true }
        return false
    }

    private var statusColor: Color {
        switch state {
        case .connected: return .green
        case .connecting: return .orange
        case .idle: return .gray
        case .disconnected: return .red
        }
    }

    private var statusText: String {
        switch state {
        case .idle: return "Idle"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .disconnected(let reason):
            if let reason, !reason.isEmpty { return "Disconnected — \(reason)" }
            return "Disconnected"
        }
    }
}

private struct PlaceholderView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No open sessions")
                .font(.title3)
            Text("Double-click a connection in the sidebar to open it.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

/// Shown for a connection whose protocol KRemote cannot open yet.
private struct UnsupportedProtocolView: View {
    let name: String
    let protocolName: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.orange)
            Text(name).font(.title3)
            Text("\(protocolName.isEmpty ? "This protocol" : protocolName) is not supported yet. Only SSH sessions can be opened.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
