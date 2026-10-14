import SwiftUI
import AppKit
import SwiftTerm
import KRemoteCore

/// Bridges a SwiftTerm `TerminalView` to an `SSHPtySession`:
/// keystrokes go to the ssh process, its output is fed to the emulator, and
/// terminal resizes are reported back over the PTY.
///
/// `inputRequests` is a counter the parent bumps to ask the terminal to write a
/// command (e.g. `sudo -i`) to the shell; `onInputRequestHandled` fires afterward.
/// Focus is reported via a local mouse monitor, because SwiftTerm's
/// `becomeFirstResponder` is not `open` and cannot be overridden.
struct TerminalSessionView: NSViewRepresentable {
    let host: String
    let port: Int
    let username: String
    let password: String
    let identityFile: String
    let remoteCommand: String

    var inputRequests: Int = 0
    /// Command written when `inputRequests` changes (e.g. `sudo -S -i`).
    var pendingCommand: String = ""
    /// Password written (with a newline) shortly after the command, when the
    /// command reads one from stdin. Empty means nothing is auto-sent.
    var pendingPassword: String = ""

    let onStateChange: @MainActor (SSHPtySession.State) -> Void
    let onTitleChange: @MainActor (String) -> Void
    var onFocus: @MainActor () -> Void = {}
    var onInputRequestHandled: @MainActor () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(
            host: host,
            port: port,
            username: username,
            password: password,
            identityFile: identityFile,
            remoteCommand: remoteCommand
        )
    }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        context.coordinator.attach(view: view, onStateChange: onStateChange, onTitleChange: onTitleChange)
        context.coordinator.installFocusMonitor(view: view, onFocus: onFocus)
        context.coordinator.lastInputRequest = inputRequests
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        context.coordinator.updateFocusHandler(onFocus)
        // Fire only when the counter *increases*. A decrease happens when a
        // session stops being the root target, and must not be mistaken for a
        // fresh request.
        let previous = context.coordinator.lastInputRequest
        if inputRequests != previous {
            context.coordinator.lastInputRequest = inputRequests
            if inputRequests > previous, !pendingCommand.isEmpty {
                context.coordinator.runPending(command: pendingCommand, password: pendingPassword)
                onInputRequestHandled()
            }
        }
    }

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
        private let identityFile: String
        private let remoteCommand: String

        private weak var view: TerminalView?
        private var session: SSHPtySession?
        private var onTitleChange: (@MainActor (String) -> Void)?
        private var focusMonitor: Any?
        private var onFocus: (@MainActor () -> Void)?

        var lastInputRequest = 0

        init(
            host: String,
            port: Int,
            username: String,
            password: String,
            identityFile: String,
            remoteCommand: String
        ) {
            self.host = host
            self.port = port
            self.username = username
            self.password = password
            self.identityFile = identityFile
            self.remoteCommand = remoteCommand
        }

        func installFocusMonitor(view: TerminalView, onFocus: @escaping @MainActor () -> Void) {
            self.onFocus = onFocus
            // A click anywhere in this terminal means it is the active pane.
            focusMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak view] event in
                if let view, event.window === view.window, view.bounds.contains(view.convert(event.locationInWindow, from: nil)) {
                    Task { @MainActor in onFocus() }
                }
                return event
            }
        }

        func updateFocusHandler(_ handler: @escaping @MainActor () -> Void) {
            self.onFocus = handler
        }

        func attach(
            view: TerminalView,
            onStateChange: @escaping @MainActor (SSHPtySession.State) -> Void,
            onTitleChange: @escaping @MainActor (String) -> Void
        ) {
            self.view = view
            self.onTitleChange = onTitleChange

            let session = SSHPtySession(
                onOutput: { [weak self] data in
                    let bytes = [UInt8](data)
                    Task { @MainActor in
                        self?.feed(bytes)
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
            let command = SSHCommandBuilder(
                host: host,
                port: port,
                username: username,
                identityFile: identityFile,
                remoteCommand: remoteCommand
            )

            // SwiftUI may not hand keyboard focus to an NSViewRepresentable.
            DispatchQueue.main.async { [weak view] in
                guard let view, let window = view.window else { return }
                window.makeFirstResponder(view)
            }

            session.start(command: command, password: password, columns: columns, rows: rows)
        }

        /// Feeds PTY bytes to the terminal. Runs on the main actor: the
        /// session's output callback is `@Sendable` and must not touch the view
        /// itself, so it hands the bytes over and lets this hop do the rest.
        private func feed(_ bytes: [UInt8]) {
            view?.feed(byteArray: ArraySlice(bytes))
        }

        /// Writes raw text to the ssh process (used for the root command).
        func write(_ text: String) {
            session?.send(Data(text.utf8))
        }

        /// Writes a command, then the password a moment later if the command reads
        /// one from stdin (`sudo -S`). The delay lets the shell start reading.
        func runPending(command: String, password: String) {
            write(command + "\n")
            guard !password.isEmpty else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.write(password + "\n")
            }
        }

        func stop() {
            if let focusMonitor {
                NSEvent.removeMonitor(focusMonitor)
                self.focusMonitor = nil
            }
            session?.disconnect()
            session = nil
        }

        // MARK: TerminalViewDelegate

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
