import SwiftUI
import KRemoteCore

/// Right-hand side: the toolbar, the tab strip and the terminal area. The
/// terminal area is one pane, or a 2–4 pane split.
struct DetailView: View {
    @Environment(AppModel.self) private var model
    /// Bumped to ask the focused terminal to run `sudo -i`.
    @State private var rootRequest = 0

    var body: some View {
        @Bindable var model = model

        if model.sessions.isEmpty {
            PlaceholderView()
        } else {
            VStack(spacing: 0) {
                SessionToolbar(rootRequest: $rootRequest)
                TabStrip()
                Divider()
                PaneGrid(rootRequest: rootRequest)
            }
        }
    }
}

// MARK: - Toolbar

private struct SessionToolbar: View {
    @Environment(AppModel.self) private var model
    @Binding var rootRequest: Int

    var body: some View {
        HStack(spacing: 8) {
            Button {
                rootRequest += 1
            } label: {
                Image(systemName: "number")
            }
            .help("Become root on the focused session (runs sudo -i)")
            .disabled(model.focusedSession == nil)

            Divider().frame(height: 16)

            Button {
                model.setSplit(!model.splitMode, panes: model.splitMode ? nil : 2)
            } label: {
                Image(systemName: "square.split.2x1")
            }
            .help(model.splitMode ? "Exit split view" : "Split into two panes")
            .disabled(model.sessions.count < 2 && !model.splitMode)

            if model.splitMode {
                Text("Panes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(2...PaneLayout.maximum, id: \.self) { count in
                    Button("\(count)") { model.setPaneCount(count) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(count == model.tiles.count ? .accentColor : nil)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(.bar)
    }
}

// MARK: - Tabs

private struct TabStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(model.sessions) { session in
                    TabButton(session: session, isActive: session.id == model.activeSessionID) {
                        model.activeSessionID = session.id
                        if model.splitMode { model.focusTile(0) }
                    } onClose: {
                        model.closeSession(session.id)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .frame(height: 34)
        .background(.bar)
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

// MARK: - Panes

private struct PaneGrid: View {
    @Environment(AppModel.self) private var model
    let rootRequest: Int

    var body: some View {
        if model.splitMode {
            let layout = model.paneLayout
            VStack(spacing: 1) {
                ForEach(0..<layout.rows, id: \.self) { row in
                    HStack(spacing: 1) {
                        ForEach(0..<layout.columns, id: \.self) { column in
                            let index = row * layout.columns + column
                            if index < model.tiles.count {
                                PaneView(tileIndex: index, rootRequest: rootRequest)
                            } else {
                                Color(nsColor: .windowBackgroundColor)
                            }
                        }
                    }
                }
            }
            .background(Color(nsColor: .separatorColor))
        } else {
            PaneView(tileIndex: 0, rootRequest: rootRequest)
        }
    }
}

private struct PaneView: View {
    @Environment(AppModel.self) private var model
    let tileIndex: Int
    let rootRequest: Int

    private var isFocused: Bool { model.focusedTile == tileIndex }

    var body: some View {
        let sessionID = model.tiles.indices.contains(tileIndex) ? model.tiles[tileIndex] : nil

        VStack(spacing: 0) {
            paneHeader(sessionID: sessionID)
            Divider()
            if let sessionID, let session = model.sessions.first(where: { $0.id == sessionID }) {
                SessionContent(session: session, isFocused: isFocused, rootRequest: rootRequest)
            } else {
                EmptyPaneView(tileIndex: tileIndex)
            }
        }
        .overlay(
            Rectangle()
                .strokeBorder(isFocused ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.focusTile(tileIndex) }
    }

    @ViewBuilder
    private func paneHeader(sessionID: Session.ID?) -> some View {
        HStack(spacing: 6) {
            if let sessionID, let session = model.sessions.first(where: { $0.id == sessionID }) {
                Menu(session.displayTitle) {
                    ForEach(model.sessions) { candidate in
                        Button(candidate.displayTitle) {
                            model.assign(candidate.id, toTile: tileIndex)
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .font(.caption)
                .fixedSize()
            } else {
                Text("Empty pane").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.splitMode {
                Text("Pane \(tileIndex + 1)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(isFocused ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
    }
}

private struct EmptyPaneView: View {
    @Environment(AppModel.self) private var model
    let tileIndex: Int

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Pick a session for this pane")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !model.sessions.isEmpty {
                Menu("Show…") {
                    ForEach(model.sessions) { candidate in
                        Button(candidate.displayTitle) {
                            model.assign(candidate.id, toTile: tileIndex)
                        }
                    }
                }
                .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

/// A live terminal for one session, including status and reconnect.
private struct SessionContent: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let isFocused: Bool
    let rootRequest: Int

    @State private var state: SSHPtySession.State = .idle

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            if let node = model.find(session.nodeID), node.supportsSSH {
                let effective = model.effective(node.id)
                TerminalSessionView(
                    host: effective?.host ?? "",
                    port: effective?.port ?? 22,
                    username: effective?.username ?? "",
                    password: effective?.password ?? "",
                    identityFile: effective?.identityFile ?? "",
                    remoteCommand: effective?.remoteCommand ?? "",
                    inputRequests: shouldSendRoot ? rootRequest : 0,
                    pendingInput: "sudo -i\n",
                    onStateChange: { newState in
                        guard model.currentGeneration(of: session.id) == session.generation else { return }
                        state = newState
                        if case .disconnected(let reason) = newState, reason == nil {
                            model.closeSession(session.id)
                        }
                    },
                    onTitleChange: { model.updateTitle(session.id, title: $0) },
                    onFocus: { model.focusTile(model.tileIndex(of: session.id) ?? model.focusedTile) }
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
    }

    /// Only the focused pane answers the root request.
    private var shouldSendRoot: Bool {
        isFocused && model.focusedSession?.id == session.id
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
        .frame(height: 26)
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
