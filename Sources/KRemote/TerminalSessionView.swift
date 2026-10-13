import SwiftUI
import AppKit
import SwiftTerm
import KRemoteCore

/// Bridges a SwiftTerm `TerminalView` to an `SSHPtySession`:
/// keystrokes go to the ssh process, its output is fed to the emulator, and
/// terminal resizes are reported back over the PTY.
struct TerminalSessionView: NSViewRepresentable {
    let host: String
    let port: Int
    let username: String
    let password: String
    let onStateChange: @MainActor (SSHPtySession.State) -> Void
    let onTitleChange: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(host: host, port: port, username: username, password: password)
    }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        context.coordinator.attach(
            view: view,
            onStateChange: onStateChange,
            onTitleChange: onTitleChange
        )
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {}

    static func dismantleNSView(_ view: TerminalView, coordinator: Coordinator) {
        coordinator.stop()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        private let host: String
        private let port: Int
        private let username: String
        private let password: String

        private weak var view: TerminalView?
        private var session: SSHPtySession?
        private var onTitleChange: (@MainActor (String) -> Void)?

        init(host: String, port: Int, username: String, password: String) {
            self.host = host
            self.port = port
            self.username = username
            self.password = password
        }

        func attach(
            view: TerminalView,
            onStateChange: @escaping @MainActor (SSHPtySession.State) -> Void,
            onTitleChange: @escaping @MainActor (String) -> Void
        ) {
            self.view = view
            self.onTitleChange = onTitleChange

            let session = SSHPtySession(
                onOutput: { [weak view] data in
                    Task { @MainActor in
                        view?.feed(byteArray: ArraySlice([UInt8](data)))
                    }
                },
                onStateChange: { state in
                    Task { @MainActor in onStateChange(state) }
                }
            )
            self.session = session

            let terminal = view.getTerminal()
            let columns = max(2, terminal.cols)
            let rows = max(2, terminal.rows)
            let command = SSHCommandBuilder(host: host, port: port, username: username)

            // SwiftUI may not hand keyboard focus to an NSViewRepresentable.
            // Make the terminal first responder once it is in a window so keys
            // reach `send(source:data:)` at all.
            DispatchQueue.main.async { [weak view] in
                guard let view, let window = view.window else { return }
                window.makeFirstResponder(view)
            }

            session.start(command: command, password: password, columns: columns, rows: rows)
        }

        func stop() {
            session?.disconnect()
            session = nil
        }

        // MARK: TerminalViewDelegate
        //
        // SwiftTerm's delegate protocol is nonisolated, but we are @MainActor. The
        // callbacks are delivered on the main thread, so `nonisolated` plus
        // `MainActor.assumeIsolated` is the correct bridge — no hop needed.

        nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
            MainActor.assumeIsolated {
                session?.send(Data(data))
            }
        }

        nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated {
                session?.resize(columns: newCols, rows: newRows)
            }
        }

        nonisolated func setTerminalTitle(source: TerminalView, title: String) {
            MainActor.assumeIsolated {
                onTitleChange?(title)
            }
        }

        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        nonisolated func scrolled(source: TerminalView, position: Double) {}

        nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}

        nonisolated func bell(source: TerminalView) {
            MainActor.assumeIsolated { NSSound.beep() }
        }

        nonisolated func clipboardCopy(source: TerminalView, content: Data) {
            MainActor.assumeIsolated {
                if let text = String(data: content, encoding: .utf8) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
        }

        nonisolated func clipboardRead(source: TerminalView) -> Data? {
            MainActor.assumeIsolated {
                NSPasteboard.general.string(forType: .string).map { Data($0.utf8) }
            }
        }

        nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

        nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
