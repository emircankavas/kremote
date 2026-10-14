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

    func makeCoordinator() -> Coordinator {
        Coordinator(
            host: host,
            port: port,
            username: username,
            password: password,
            options: options
        )
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
        private var focusMonitor: Any?
        private var onFocus: (@MainActor () -> Void)?

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
            self.client = client
            view.attach(client: client)

            // The connection needs the pane's real size before it starts, so the
            // first frame is not letterboxed.
            let size = view.bounds.size.width > 0 ? view.bounds.size : CGSize(width: 1024, height: 768)
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
            client?.disconnect()
            client = nil
        }
    }
}

/// An AppKit view that owns the FreeRDP drawing surface and forwards input.
///
/// Mouse and keyboard handling live here rather than in SwiftUI: FreeRDP needs
/// raw scancodes and button masks, and the remote cursor is hardware-painted.
final class RDPHostView: NSView {
    private var client: RDPClient?
    /// Previous modifier state, so `flagsChanged` can tell a press from a release
    /// (AppKit sends one event for both).
    private var lastModifierFlags: NSEvent.ModifierFlags = []

    func attach(client: RDPClient) {
        self.client = client
    }

    /// Blits a decoded frame. Called on FreeRDP's session thread, so it hops to
    /// the main actor before touching the layer; the C buffer is only valid for
    /// the duration of the call, hence the copy into a CGImage here.
    func presentFrame(bgra: UnsafePointer<UInt8>?, width: Int, height: Int, stride: Int) {
        guard let bgra, width > 0, height > 0, stride > 0 else { return }
        // Copy out of FreeRDP's paint buffer before leaving this call.
        let byteCount = stride * height
        let copy = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
        copy.copyMemory(from: bgra, byteCount: byteCount)
        Task { @MainActor [weak self] in
            guard let self else { copy.deallocate(); return }
            self.blit(copy: copy, width: width, height: height, stride: stride)
        }
    }

    @MainActor
    private func blit(copy: UnsafeMutableRawPointer, width: Int, height: Int, stride: Int) {
        defer { copy.deallocate() }
        guard let provider = CGDataProvider(
            dataInfo: nil,
            data: copy,
            size: stride * height,
            releaseData: { _, _, _ in }
        ) else { return }

        // FreeRDP's PIXEL_FORMAT_BGRA32 is little-endian BGRA, which CoreGraphics
        // spells as 32-bit little-endian with a skip-first (bgra) layout.
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: stride,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return }

        wantsLayer = true
        layer?.contents = image
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

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
        client?.resize(to: bounds.size)
    }

    // MARK: - Input

    override func mouseDown(with event: NSEvent) { forwardMouse(event) }
    override func mouseUp(with event: NSEvent) { forwardMouse(event) }
    override func rightMouseDown(with event: NSEvent) { forwardMouse(event) }
    override func rightMouseUp(with event: NSEvent) { forwardMouse(event) }
    override func otherMouseDown(with event: NSEvent) { forwardMouse(event) }
    override func otherMouseUp(with event: NSEvent) { forwardMouse(event) }
    override func mouseMoved(with event: NSEvent) {
        client?.sendMouseMove(at: convert(event.locationInWindow, from: nil))
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
        let point = convert(event.locationInWindow, from: nil)
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
