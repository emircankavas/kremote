import SwiftUI
import KRemoteCore

/// Right-hand side: the tab strip plus the active session's content.
struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.sessions.isEmpty {
            PlaceholderView()
        } else {
            VStack(spacing: 0) {
                TabStrip()
                Divider()
                // Keep EVERY session in the hierarchy (just hide the inactive
                // ones) so switching tabs does not tear down its ssh process.
                ZStack {
                    ForEach(model.sessions) { session in
                        SessionView(session: session)
                            .opacity(session.id == model.activeSessionID ? 1 : 0)
                            .allowsHitTesting(session.id == model.activeSessionID)
                    }
                }
            }
        }
    }
}

private struct TabStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(model.sessions) { session in
                    TabButton(session: session, isActive: session.id == model.activeSessionID) {
                        model.activeSessionID = session.id
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

/// Hosts a live SSH terminal for a connection, wired through SwiftTerm.
struct SessionView: View {
    @Environment(AppModel.self) private var model
    let session: Session

    @State private var state: SSHPtySession.State = .idle

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            if let node = model.find(session.nodeID) {
                let effective = model.effective(node.id)
                TerminalSessionView(
                    host: effective?.host ?? "",
                    port: effective?.port ?? 22,
                    username: effective?.username ?? "",
                    password: effective?.password ?? "",
                    identityFile: effective?.identityFile ?? "",
                    remoteCommand: effective?.remoteCommand ?? "",
                    onStateChange: { state = $0 },
                    onTitleChange: { model.updateTitle(session.id, title: $0) }
                )
                // A new generation rebuilds the view → a fresh ssh process.
                .id(session.generation)
            } else {
                Text("Connection no longer exists.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
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
        .frame(height: 28)
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
