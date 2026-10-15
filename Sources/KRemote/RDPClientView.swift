import SwiftUI
import AppKit
import KRemoteCore

/// The connection state of an RDP pane, mirroring `SSHPtySession.State` so the
/// two status bars read the same way.
enum RDPClientState: Equatable {
    case idle
    case connecting
    case connected
    /// The remote ended the session (or the user closed it); `nil` reason means
    /// a clean close, which closes the tab.
    case disconnected(String?)
    /// The connection could not be established (bad credentials, unreachable
    /// host, certificate refused).
    case failed(String)
}

/// Hosts the AppKit view that FreeRDP draws into.
///
/// SwiftUI owns no RDP transport today: `RDPClient` is the FreeRDP-backed
/// implementation. When a build is made without the FreeRDP library,
/// `RDPClientView` falls back to a notice (see `DetailView`), so the tree and
/// editor still work everywhere.
struct RDPClientView: NSViewRepresentable {
    let host: String
    let port: Int
    let username: String
    let password: String
    let options: RDPOptions

    let onStateChange: @MainActor (RDPClientState) -> Void
    var onFocus: @MainActor () -> Void = {}
    /// Routes a credential request from the session to the UI.
    var onCredentialsNeeded: @MainActor (String, String, @escaping (RDPCredentialAnswer) -> Void) -> Void = { _, _, _ in }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(
            host: host,
            port: port,
            username: username,
            password: password,
            options: options
        )
        coordinator.onCredentialsNeeded = onCredentialsNeeded
        return coordinator
    }

    func makeNSView(context: Context) -> RDPHostView {
        let view = RDPHostView()
        context.coordinator.attach(view: view, onStateChange: onStateChange)
        context.coordinator.installFocusMonitor(view: view, onFocus: onFocus)
        return view
    }

    func updateNSView(_ view: RDPHostView, context: Context) {
        context.coordinator.updateFocusHandler(onFocus)
    }

    static func dismantleNSView(_ view: RDPHostView, coordinator: Coordinator) {
        coordinator.stop()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator {
        private let host: String
        private let port: Int
        private let username: String
        private let password: String
        private let options: RDPOptions

        private weak var view: RDPHostView?
        private var client: RDPClient?
        private var clipboard: RDPClipboardBridge?
        private var focusMonitor: Any?
        private var onFocus: (@MainActor () -> Void)?
        /// Set by the pane so credential requests reach the UI.
        var onCredentialsNeeded: (@MainActor (String, String, @escaping (RDPCredentialAnswer) -> Void) -> Void)?

        init(host: String, port: Int, username: String, password: String, options: RDPOptions) {
            self.host = host
            self.port = port
            self.username = username
            self.password = password
            self.options = options
        }

        func installFocusMonitor(view: RDPHostView, onFocus: @escaping @MainActor () -> Void) {
            self.onFocus = onFocus
            // RDP draws into a child view of the pane; a click anywhere in it
            // means this pane is the active split tile.
            focusMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak view] event in
                if let view, event.window === view.window,
                   view.bounds.contains(view.convert(event.locationInWindow, from: nil)) {
                    Task { @MainActor in onFocus() }
                }
                return event
            }
        }

        func updateFocusHandler(_ handler: @escaping @MainActor () -> Void) {
            self.onFocus = handler
        }

        func attach(view: RDPHostView, onStateChange: @escaping @MainActor (RDPClientState) -> Void) {
            self.view = view
            guard RDPClient.isAvailable else { return }

            let client = RDPClient(onStateChange: { state in
                Task { @MainActor in onStateChange(state) }
            })
            client.onCredentialsNeeded = onCredentialsNeeded
            // Keep clipboard text flowing both ways while this pane owns the
            // session; the bridge stops polling when it goes away.
            let clipboard = RDPClipboardBridge(client: client)
            client.onRemoteClipboardText = { [weak clipboard] text in
                clipboard?.applyRemoteText(text)
            }
            clipboard.start()
            self.clipboard = clipboard
            self.client = client
            view.attach(client: client)

            // The connection needs the pane's real size before it starts, so the
            // first frame is not letterboxed — and in *pixels*, not points, so a
            // Retina pane gets a full-resolution desktop.
            let size = view.bounds.width > 0 ? view.backingPixelSize : CGSize(width: 1280, height: 800)
            client.connect(
                host: host,
                port: port,
                username: username,
                password: password,
                options: options,
                view: view,
                size: size
            )
        }

        func stop() {
            if let focusMonitor {
                NSEvent.removeMonitor(focusMonitor)
                self.focusMonitor = nil
            }
            clipboard?.stop()
            clipboard = nil
            client?.disconnect()
            client = nil
        }
    }
}

/// Mirrors text between the macOS pasteboard and the remote clipboard.
///
/// FreeRDP's clipboard channel is event-driven, but macOS gives no reliable
/// "clipboard changed" notification that covers every source, so the local side
/// is polled: cheap, and it keeps both directions working without the app having
/// to become a pasteboard server.
@MainActor
final class RDPClipboardBridge {
    /// What we last pushed to the remote side, so polling does not re-announce
    /// our own echoes (which would ping-pong between the two ends).
    private var lastSentText: String?
    /// File URLs last announced, on the same principle as `lastSentText`.
    private var lastSentFiles: [String]?
    private var timer: Timer?
    private weak var client: RDPClient?

    /// The remote clipboard is only ours while this pane is frontmost, so the
    /// pasteboard is not silently overwritten by a background session.
    private var ownsPasteboard: Bool {
        NSApp.isActive && (NSApp.keyWindow?.firstResponder is RDPHostView)
    }

    init(client: RDPClient) {
        self.client = client
    }

    func start() {
        guard let client else { return }
        // Announce whatever the user already had copied, so paste works right away.
        announceCurrentPasteboard(client)
        // Cancels the eyes-closed situation where a poller dies with the view.
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        client = nil
    }

    /// Pushes the pasteboard to the server. Files win over text: when a file copy
    /// happens Finder also puts a text representation on the pasteboard, and the
    /// file is what the user meant.
    private func announceCurrentPasteboard(_ client: RDPClient) {
        let files = currentFilePaths()
        lastSentFiles = files
        lastSentText = NSPasteboard.general.string(forType: .string)
        if !files.isEmpty {
            client.setLocalClipboardFiles(files)
        } else if let text = lastSentText, !text.isEmpty {
            client.setLocalClipboardText(text)
        }
    }

    /// File paths the pasteboard currently holds, if any.
    private func currentFilePaths() -> [String] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        let objects = NSPasteboard.general.readObjects(
            forClasses: [NSURL.self], options: options
        ) as? [URL]
        return (objects ?? []).map(\.path)
    }

    /// Pushes local clipboard changes to the server.
    private func poll() {
        guard let client, ownsPasteboard else { return }
        let files = currentFilePaths()
        if files != lastSentFiles {
            lastSentFiles = files
            if !files.isEmpty {
                client.setLocalClipboardFiles(files)
                return
            }
        }
        if !files.isEmpty { return }   // files unchanged and still current
        let current = NSPasteboard.general.string(forType: .string) ?? ""
        guard current != lastSentText else { return }
        lastSentText = current
        client.setLocalClipboardText(current)
    }

    /// Applies text the server sent. `lastSentText` is updated so the next poll
    /// does not bounce it straight back.
    func applyRemoteText(_ text: String) {
        lastSentText = text
        guard ownsPasteboard else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// An AppKit view that owns the FreeRDP drawing surface and forwards input.
///
/// Mouse and keyboard handling live here rather than in SwiftUI: FreeRDP needs
/// raw scancodes and button masks, and the remote cursor is hardware-painted.
/// Every method runs on the main actor (AppKit and the sink both call here on
/// the main thread).
@MainActor
final class RDPHostView: NSView {
    private var client: RDPClient?
    /// Previous modifier state, so `flagsChanged` can tell a press from a release
    /// (AppKit sends one event for both).
    private var lastModifierFlags: NSEvent.ModifierFlags = []
    /// Size of the remote desktop in its own pixels, as last reported by a frame.
    /// Needed to map a click in this view (points) onto the remote surface.
    private var desktopSize = CGSize.zero

    func attach(client: RDPClient) {
        self.client = client
        wantsLayer = true
        // The remote image is in remote pixels, the layer is in points; let the
        // layer scale it so a Retina desktop is shown at full detail.
        layer?.contentsGravity = .resize
        // Frames arrive continuously; CoreAnimation's implicit fade between
        // `contents` assignments makes that a smear and piles work on the main
        // thread. The eye does not want an animation here — it wants the newest
        // frame, immediately.
        layer?.actions = [
            "contents": NSNull(),
            "onOrderIn": NSNull(),
            "onOrderOut": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
        ]
    }

    /// This view's size in device pixels — what the remote desktop should be.
    ///
    /// Requesting the desktop in *points* is what made it look low-resolution:
    /// on a Retina display the screen has twice the pixels, so a point-sized
    /// desktop is half the available detail.
    var backingPixelSize: CGSize {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        return CGSize(width: size.width.rounded(), height: size.height.rounded())
    }

    /// Maps a point in this view onto the remote desktop's pixel grid.
    ///
    /// Without this, a click on a Retina Mac is reported at half its real
    /// position (and every other scale — fit-to-panel, fullscreen — is off too).
    private func remotePoint(_ local: CGPoint) -> CGPoint {
        guard desktopSize.width > 0, desktopSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return local
        }
        return CGPoint(
            x: local.x * desktopSize.width / bounds.width,
            y: local.y * desktopSize.height / bounds.height
        )
    }

    /// Shows a finished frame. The CGImage was built on FreeRDP's thread, so the
    /// main thread only assigns it. Only the most recent frame matters: if several
    /// arrived while main was busy, the newest wins and the rest are dropped, which
    /// keeps the picture live instead of playing catch-up.
    func presentFrame(_ image: CGImage) {
        desktopSize = CGSize(width: image.width, height: image.height)
        wantsLayer = true
        // Wrapped so the assignment is not animated (see `attach`).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    /// Without a tracking area AppKit never delivers `mouseMoved`, so the remote
    /// cursor would only update on a click or drag and every click would land at
    /// a stale position.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Without this the view never receives key events (SwiftUI often does not
        // make an NSViewRepresentable first responder on its own).
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func layout() {
        super.layout()
        client?.resize(to: backingPixelSize)
    }

    // MARK: - Input

    override func mouseDown(with event: NSEvent) { forwardMouse(event) }
    override func mouseUp(with event: NSEvent) { forwardMouse(event) }
    override func rightMouseDown(with event: NSEvent) { forwardMouse(event) }
    override func rightMouseUp(with event: NSEvent) { forwardMouse(event) }
    override func otherMouseDown(with event: NSEvent) { forwardMouse(event) }
    override func otherMouseUp(with event: NSEvent) { forwardMouse(event) }
    override func mouseMoved(with event: NSEvent) {
        client?.sendMouseMove(at: remotePoint(convert(event.locationInWindow, from: nil)))
    }
    override func mouseDragged(with event: NSEvent) { forwardMouse(event) }
    override func rightMouseDragged(with event: NSEvent) { forwardMouse(event) }
    override func otherMouseDragged(with event: NSEvent) { forwardMouse(event) }
    override func scrollWheel(with event: NSEvent) {
        client?.scroll(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
    }

    override func keyDown(with event: NSEvent) {
        client?.sendKey(keyCode: event.keyCode, isDown: true)
    }

    override func keyUp(with event: NSEvent) {
        client?.sendKey(keyCode: event.keyCode, isDown: false)
    }

    override func flagsChanged(with event: NSEvent) {
        // Modifier keys only fire `flagsChanged`, once for press and once for
        // release; the direction comes from comparing against the previous state.
        let relevant: NSEvent.ModifierFlags = [.shift, .control, .option, .command, .capsLock]
        let current = event.modifierFlags.intersection(relevant)
        let previous = lastModifierFlags.intersection(relevant)
        lastModifierFlags = event.modifierFlags

        let scancode = event.keyCode
        let isDown = current.rawValue & ~previous.rawValue != 0
        let wasDown = previous.rawValue & ~current.rawValue != 0
        if isDown || wasDown {
            client?.sendKey(keyCode: scancode, isDown: isDown)
        }
    }

    private func forwardMouse(_ event: NSEvent) {
        let point = remotePoint(convert(event.locationInWindow, from: nil))
        client?.sendMouse(at: point, button: button(for: event), isDown: isDown(event))
    }
    private func button(for event: NSEvent) -> RDPClient.MouseButton {
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged: return .left
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged: return .right
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            return event.buttonNumber == 2 ? .middle : .left
        default: return .none
        }
    }

    private func isDown(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: return true
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: return false
        default: return event.type == .leftMouseDragged
            || event.type == .rightMouseDragged
            || event.type == .otherMouseDragged
        }
    }
}
