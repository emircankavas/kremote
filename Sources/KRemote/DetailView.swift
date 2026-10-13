import SwiftUI

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
                if let session = model.activeSession {
                    SessionView(session: session)
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
            Text(session.title)
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

/// Faz 1 stand-in. Faz 3 replaces the body with an embedded SwiftTerm view
/// backed by a live SSH transport.
struct SessionView: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let node = model.find(session.nodeID) {
                Text(node.name).font(.headline)
                Text(model.effective(node.id)?.summary ?? "not configured")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Terminal session lands here in Faz 3.")
                .font(.callout)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding()
    }
}
