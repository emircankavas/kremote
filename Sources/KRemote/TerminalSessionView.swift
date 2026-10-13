import SwiftUI
import AppKit
import SwiftTerm
import KRemoteCore

/// Bridges a SwiftTerm `TerminalView` to an `SSHSessionController`:
/// keystrokes go to the SSH channel, channel output is fed to the emulator,
/// and terminal resizes are reported back to the server.
struct TerminalSessionView: NSViewRepresentable {
    let nodeID: ConnectionNode.ID
    let host: String
    let port: Int
    let username: String
    let password: String
    let onStateChange: (SSHSessionController.State) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(nodeID: nodeID, host: host, port: port, username: username, password: password)
    }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        context.coordinator.attach(view: view, onStateChange: onStateChange)
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        // Nothing to do: the session owns its own state once started.
    }

    static func dismantleNSView(_ view: TerminalView, coordinator: Coordinator) {
        coordinator.stop()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        private let nodeID: ConnectionNode.ID
        private let host: String
        private let port: Int
        private let username: String
        private let password: String

        private weak var view: TerminalView?
        private var controller: SSHSessionController?

        init(nodeID: ConnectionNode.ID, host: String, port: Int, username: String, password: String) {
            self.nodeID = nodeID
            self.host = host
            self.port = port
            self.username = username
            self.password = password
        }

        func attach(view: TerminalView, onStateChange: @escaping (SSHSessionController.State) -> Void) {
            self.view = view

            let controller = SSHSessionController(
                onOutput: { [weak view] data in
                    Task { @MainActor in
                        view?.feed(byteArray: ArraySlice([UInt8](data)))
                    }
                },
                onStateChange: { state in
                    Task { @MainActor in onStateChange(state) }
                }
            )
            self.controller = controller

            let (columns, rows) = Self.size(of: view)
            Task {
                await controller.connect(
                    host: host,
                    port: port,
                    username: username,
                    password: password,
                    columns: columns,
                    rows: rows
                )
            }
        }

        func stop() {
            guard let controller else { return }
            Task { await controller.disconnect() }
            self.controller = nil
        }

        private static func size(of view: TerminalView) -> (Int, Int) {
            let columns = max(2, view.getTerminal().cols)
            let rows = max(2, view.getTerminal().rows)
            return (columns, rows)
        }

        // MARK: TerminalViewDelegate

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            guard let controller else { return }
            Task { await controller.send(Data(data)) }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard let controller else { return }
            Task { await controller.resize(columns: newCols, rows: newRows) }
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            // Could surface the remote title in the tab; ignored for now.
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func scrolled(source: TerminalView, position: Double) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}

        func bell(source: TerminalView) {
            NSSound.beep()
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }

        func clipboardRead(source: TerminalView) -> Data? {
            NSPasteboard.general.string(forType: .string).map { Data($0.utf8) }
        }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
