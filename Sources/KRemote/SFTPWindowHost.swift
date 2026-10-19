import SwiftUI
import KRemoteCore

/// Hosts one SFTP window: resolves the session for a node id and keeps the
/// window bound to it for its whole life.
///
/// The session lives on `AppModel` (not in a `@State` here) so that asking for
/// the same connection again finds it and focuses the window instead of opening
/// a second browser on the same server.
struct SFTPWindowHost: View {
    @Environment(AppModel.self) private var model
    let nodeID: UUID?
    @State private var isClosing = false

    var body: some View {
        if let nodeID, let session = model.sftpSession(for: nodeID) {
            SFTPWindowView(session: session)
                .onDisappear {
                    // `onDisappear` can fire more than once; tear the connection
                    // down only once.
                    guard !isClosing else { return }
                    isClosing = true
                    model.closeSFTP(session.id)
                }
        } else {
            ContentUnavailableView(
                "No SFTP session",
                systemImage: "network.slash",
                description: Text("Open SFTP from a connection's toolbar or its context menu.")
            )
            .frame(width: 460, height: 260)
        }
    }
}
