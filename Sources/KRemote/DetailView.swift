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
        // The tab strip lives in the window toolbar (see `ContentView`), so the
        // detail area is just the session surface. Chrome-style: tabs share the
        // title bar with the window controls instead of taking a row of their own.
        if model.sessions.isEmpty {
            PlaceholderView()
        } else {
            TerminalArea()
        }
    }
}

// MARK: - Tab strip (lives in the window toolbar)

/// The session tabs, shown in the window's title bar.
///
/// Sized for a toolbar rather than a content row: shorter padding, and each tab
/// is capped so a long title cannot push its neighbours out of view.
struct TabStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(model.sessions) { session in
                    TabButton(
                        session: session,
                        label: model.tabLabel(for: session.id),
                        isActive: session.id == model.activeSessionID
                    ) {
                        model.activateTab(session.id)
                    } onClose: {
                        model.closeSession(session.id)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(maxWidth: 720)
    }
}

private struct TabButton: View {
    let session: Session
    /// The label to show: the connection's name, with a trailing number when the
    /// same connection is open more than once.
    let label: String
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "terminal")
                .font(.caption2)
            Text(label)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .opacity(isHovering || isActive ? 1 : 0)
            .help("Close tab")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: 180)
        .background(
            RoundedRectangle(cornerRadius: 5)
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
            let cellW = (geometry.size.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
            let cellH = (geometry.size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)

            ZStack(alignment: .topLeading) {
                // Every session stays mounted for its whole life; only the ones in
                // a pane are placed in a cell and shown.
                //
                // Hidden sessions are parked *at their real pane size*, off to the
                // right of the visible cells. They must NOT be shrunk to 1x1:
                // SwiftTerm clamps a terminal to MINIMUM_COLS = 2 / MINIMUM_ROWS = 1,
                // so a hidden pane becomes a 2-column terminal. Any output that
                // arrives while it is hidden (a prompt redraw, a background job)
                // gets wrapped at 2 columns and survives into the visible buffer,
                // leaving the tail of the last line mangled. Parked views keep
                // their size instead, so resizing never touches the emulator.
                ForEach(model.sessions) { session in
                    SessionContent(
                        session: session,
                        isFocused: focused(session),
                        showPaneChrome: model.splitMode,
                        onFocus: { model.focus(session.id) }
                    )
                    .frame(width: cellW, height: cellH)
                    .offset(
                        offset(
                            for: session,
                            cellWidth: cellW,
                            cellHeight: cellH,
                            columns: columns,
                            gridWidth: cellW * CGFloat(columns) + gap * CGFloat(columns - 1)
                        )
                    )
                    .opacity(isVisible(session) ? 1 : 0)
                    .allowsHitTesting(isVisible(session))
                }

                // Empty panes sit on top of the parked views.
                if model.splitMode {
                    ForEach(emptyTileIndices, id: \.self) { index in
                        EmptyPaneView(tileIndex: index)
                            .frame(width: cellW, height: cellH)
                            .offset(cellOffset(index, cellWidth: cellW, cellHeight: cellH, columns: columns))
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

    /// Placement for every session. Hidden ones are parked to the right of the
    /// whole grid — far enough that they can never overlap a visible cell — at
    /// full pane size, so their terminal geometry is untouched.
    private func offset(
        for session: Session,
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        columns: Int,
        gridWidth: CGFloat
    ) -> CGSize {
        guard let index = visibleTileIndex(of: session) else {
            return CGSize(width: gridWidth + 16, height: 0)
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
    let isFocused: Bool
    let showPaneChrome: Bool
    let onFocus: () -> Void

    @State private var state: SSHPtySession.State = .idle

    var body: some View {
        VStack(spacing: 0) {
            if showPaneChrome { paneHeader }
            // The status bar outside tracks `SSHPtySession.State`, which an RDP
            // session never updates — it would sit on "Idle" forever. The RDP
            // branch draws its own bar instead, so skipping this one is also what
            // removes the second, stale bar the pane used to show.
            if isRDP {
                terminal
            } else {
                statusBar
                Divider()
                terminal
            }
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

    /// An RDP session, which supplies its own chrome.
    private var isRDP: Bool {
        guard let node = model.find(session.nodeID) else { return false }
        return !node.supportsSSH && node.supportsRDP
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
                inputRequests: model.rootTarget == session.id ? model.rootRequest : 0,
                // A snippet is delivered only to the session it was confirmed for:
                // the sheet that asks can move focus, and a script must never land
                // in a pane the user did not aim at.
                snippetRequests: model.snippetTarget == session.id ? model.snippetRequest : 0,
                snippetCommand: model.snippetTarget == session.id ? model.snippetCommand : "",
                onSnippetHandled: { model.snippetHandled() },
                // Every keystroke goes out to the other sessions while broadcasting.
                // The sink is how this pane receives theirs.
                onInput: { data in model.broadcast(data, from: session.id) },
                broadcastRequest: model.broadcastOrigin == session.id ? 0 : model.broadcastRequest,
                broadcastPayload: model.broadcastPayload,
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
                onFocus: { model.focus(session.id) }
            )
            .id(session.generation)
        } else if let node = model.find(session.nodeID), node.supportsRDP {
            RDPSessionContent(
                nodeID: node.id,
                session: session,
                showPaneChrome: showPaneChrome,
                onFocus: { model.focus(session.id) },
                onClose: { model.closeSession(session.id) }
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
            // Live load for the SSH pane. Keyed on the connection so switching a
            // session in this pane rebinds the poller rather than showing the
            // previous server's numbers.
            if isConnected {
                MetricsBadge(
                    source: .shell(
                        host: model.effective(session.nodeID)?.host ?? "",
                        port: model.effective(session.nodeID)?.port ?? 22,
                        username: model.effective(session.nodeID)?.username ?? "",
                        identityFile: model.effective(session.nodeID)?.identityFile ?? "",
                        password: model.effective(session.nodeID)?.password ?? ""
                    ),
                    isActive: true
                )
                .id(session.nodeID)
            }
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

    private var isConnected: Bool {
        if case .connected = state { return true }
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
            Text("\(protocolName.isEmpty ? "This protocol" : protocolName) is not supported yet. SSH and RDP sessions can be opened.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

/// A live RDP session (FreeRDP) with its own status bar.
///
/// Kept separate from `SessionContent`'s terminal branch because the two share
/// nothing but the session identity: an RDP pane has no root command, no remote
/// title escape and no reconnect-by-generation semantics beyond rebuilding.
private struct RDPSessionContent: View {
    @Environment(AppModel.self) private var model
    let nodeID: ConnectionNode.ID
    let session: Session
    let showPaneChrome: Bool
    /// `@MainActor` matches `RDPClientView`'s callback types; SwiftUI views are
    /// main-actor isolated, so the literals at the call site satisfy this.
    let onFocus: @MainActor () -> Void
    let onClose: @MainActor () -> Void

    @State private var state: RDPClientState = .idle

    private var options: RDPOptions { model.effective(nodeID)?.rdp ?? .default }
    private var target: String {
        let effective = model.effective(nodeID)
        let user = effective.map { options.qualifiedUser($0.username) } ?? ""
        let host = effective?.host ?? ""
        let port = effective?.port ?? 3389
        return user.isEmpty ? "\(host):\(port)" : "\(user)@\(host):\(port)"
    }

    var body: some View {
        VStack(spacing: 0) {
            // This pane draws all of its own chrome: the header in split mode and
            // always its status bar, since the outer `SessionContent` bar tracks
            // SSH state and would read "Idle" for an RDP session.
            if showPaneChrome { paneHeader }
            statusBar
            Divider()
            content
        }
        .background(.background)
        .contentShape(Rectangle())
        .onTapGesture(perform: onFocus)
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
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        if RDPClient.isAvailable {
            RDPClientView(
                host: model.effective(nodeID)?.host ?? "",
                port: model.effective(nodeID)?.port ?? 3389,
                username: model.effective(nodeID)?.username ?? "",
                password: model.effective(nodeID)?.password ?? "",
                options: options,
                onStateChange: { newState in
                    guard model.currentGeneration(of: session.id) == session.generation else { return }
                    state = newState
                    // The session ended — the remote logged off, closed the
                    // desktop, or the transport dropped. A dead tab has nothing
                    // left to show, so close it. A connection that could not be
                    // *established* is different: its reason is worth reading and
                    // a retry is plausible, so that keeps the tab and offers
                    // "Reconnect" instead.
                    //
                    // Closing is deferred a runloop turn: this runs while the
                    // pane is being updated, and removing the session re-enters
                    // SwiftUI mid-update.
                    if case .disconnected = newState {
                        DispatchQueue.main.async { onClose() }
                    }
                },
                onFocus: onFocus,
                onCredentialsNeeded: { username, domain, answer in
                    // The session thread is already blocked waiting for this; the
                    // sheet answers through AppModel, which calls `answer`.
                    model.rdpCredentialAnswer = answer
                    model.pendingRDPLogin = RDPCredentialRequest(
                        username: username.isEmpty ? (model.effective(nodeID)?.username ?? "") : username,
                        domain: domain.isEmpty ? (model.effective(nodeID)?.rdp.domain ?? "") : domain
                    )
                }
            )
            .id(session.generation)
        } else {
            missingClientNotice
        }
    }

    /// Shown when the FreeRDP library is not linked into this build.
    private var missingClientNotice: some View {
        VStack(spacing: 10) {
            Image(systemName: "display.trianglebadge.exclamationmark")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.orange)
            Text("RDP support is not available in this build")
                .font(.title3)
            Text("This build was compiled without the FreeRDP client library. Install it with `brew install freerdp` and rebuild, or use a release build which bundles it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
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
            Text(target)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Text(options.summary)
                .font(.caption2)
                .foregroundStyle(.quaternary)
                .lineLimit(1)
            // RDP carries a desktop, not counters, so the load figures come over an
            // ssh channel to the same host. When the host has no ssh (a plain
            // Windows box), the badge stays silent rather than showing an error.
            if isRDPConnected {
                // RDP cannot report counters, so this is WinRM. If WinRM is off the
                // badge draws nothing — see MetricsBadge.
                MetricsBadge(
                    source: .winrm(
                        host: model.effective(nodeID)?.host ?? "",
                        username: model.effective(nodeID)?.username ?? "",
                        password: model.effective(nodeID)?.password ?? ""
                    ),
                    isActive: true
                )
                .id(nodeID)
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

    /// A failed attempt is the one ended state that keeps the RDP tab on screen
    /// (an ended session closes it), so it is the one that offers "Reconnect".
    private var isDisconnected: Bool {
        if case .failed = state { return true }
        if case .disconnected = state { return true }
        return false
    }

    private var statusColor: Color {
        switch state {
        case .connected: return .green
        case .connecting: return .orange
        case .idle: return .gray
        case .disconnected: return .red
        case .failed: return .red
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
        case .failed(let reason): return "Failed — \(reason)"
        }
    }

    private var isRDPConnected: Bool {
        if case .connected = state { return true }
        return false
    }
}
