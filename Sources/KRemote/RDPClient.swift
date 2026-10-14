import AppKit
import KRemoteCore

/// The RDP transport seam.
///
/// FreeRDP is linked as a library (through the C bridge declared in
/// `KRDPClient.h`), not run as a subprocess, so the remote desktop is drawn
/// inside a tab or a split pane — the same place an SSH terminal lives. Shelling
/// out to `sdl-freerdp` would open its own window and make tabs and panes
/// meaningless for RDP.
///
/// The library is built from source without ffmpeg and with OpenH264 so every
/// embedded dependency stays permissive (see `scripts/build-freerdp.sh`); the
/// release bundle embeds it, so end users need nothing installed.
final class RDPClient {

    enum MouseButton {
        case none, left, right, middle
    }

    /// Whether this build can open an RDP session.
    static var isAvailable: Bool { krdp_is_available() }

    /// FreeRDP's version, for diagnostics.
    static var version: String {
        guard let cString = krdp_freerdp_version() else { return "" }
        return String(cString: cString)
    }

    private let onStateChange: @Sendable (RDPClientState) -> Void
    private var handle: OpaquePointer?
    /// Retained for the session's lifetime: the C side keeps only a raw pointer.
    private var bridge: Unmanaged<RDPBridgeCallbacks>?

    init(onStateChange: @escaping @Sendable (RDPClientState) -> Void) {
        self.onStateChange = onStateChange
    }

    func connect(
        host: String,
        port: Int,
        username: String,
        password: String,
        options: RDPOptions,
        view: RDPHostView,
        size: CGSize
    ) {
        guard Self.isAvailable else {
            onStateChange(.failed("This build has no FreeRDP client library."))
            return
        }

        let callbacks = RDPBridgeCallbacks(
            onFrame: { [weak view] bgra, width, height, stride in
                guard let view else { return }
                view.presentFrame(bgra: bgra, width: width, height: height, stride: stride)
            },
            onState: { [weak self] state, message in
                guard let self else { return }
                self.onStateChange(Self.map(state: state, message: message))
            }
        )
        let retained = Unmanaged.passRetained(callbacks)
        bridge = retained

        // A custom size is requested up front; smart size / fit / fullscreen let
        // the pane's size drive it and rely on Display Control afterwards.
        let desktop: (Int, Int)
        if let explicit = options.explicitDesktopSize {
            desktop = explicit
        } else if size.width > 0, size.height > 0 {
            desktop = (Int(size.width), Int(size.height))
        } else {
            desktop = (1280, 800)
        }

        var descriptor = krdp_descriptor()
        descriptor.port = UInt16(max(1, min(65535, port)))
        descriptor.width = Int32(desktop.0)
        descriptor.height = Int32(desktop.1)
        descriptor.color_depth = Int32(options.colorDepth)
        descriptor.ignore_certificate = true
        descriptor.redirect_clipboard = options.redirectClipboard
        descriptor.redirect_drives = options.redirectDrives
        descriptor.redirect_printers = options.redirectPrinters
        descriptor.redirect_sound = options.redirectSound
        descriptor.redirect_keys = options.redirectKeys

        let pointer = retained.toOpaque()
        // The C side copies every string, so the pointers only need to live for
        // the duration of the call — hence the nested `withCString`s.
        let created: OpaquePointer? = host.withCString { hostPointer in
            descriptor.host = hostPointer
            return withOptionalCString(username) { userPointer in
                descriptor.username = userPointer
                return withOptionalCString(password) { passwordPointer in
                    descriptor.password = passwordPointer
                    return withOptionalCString(options.domain.isEmpty ? nil : options.domain) { domainPointer in
                        descriptor.domain = domainPointer
                        return krdp_client_create(
                            &descriptor,
                            rdpFrameCallback,
                            rdpStateCallback,
                            pointer
                        )
                    }
                }
            }
        }
        guard let handle = created else {
            retained.release()
            bridge = nil
            onStateChange(.failed("Could not create the RDP client."))
            return
        }

        self.handle = handle
        if !krdp_client_start(handle) {
            krdp_client_destroy(handle)
            self.handle = nil
            retained.release()
            bridge = nil
            onStateChange(.failed("Could not start the RDP session."))
        }
    }

    func disconnect() {
        if let handle {
            krdp_client_stop(handle)
            krdp_client_destroy(handle)
            self.handle = nil
        }
        bridge?.release()
        bridge = nil
    }

    func resize(to size: CGSize) {
        guard let handle, size.width > 0, size.height > 0 else { return }
        krdp_client_resize(handle, Int32(size.width), Int32(size.height))
    }

    func sendMouse(at point: CGPoint, button: MouseButton, isDown: Bool) {
        guard let handle else { return }
        krdp_client_mouse(handle, Int32(point.x), Int32(point.y), button.cValue, isDown)
    }

    func sendMouseMove(at point: CGPoint) {
        guard let handle else { return }
        krdp_client_mouse_move(handle, Int32(point.x), Int32(point.y))
    }

    func scroll(deltaX: CGFloat, deltaY: CGFloat) {
        guard let handle else { return }
        krdp_client_scroll(handle, Int32(deltaX), Int32(deltaY))
    }

    func sendKey(keyCode: UInt16, isDown: Bool) {
        guard let handle else { return }
        var extended = false
        let scancode = krdp_scancode_from_macos(keyCode, &extended)
        guard scancode != 0 else { return }
        krdp_client_key(handle, scancode, extended, isDown)
    }

    private static func map(state: krdp_state, message: String?) -> RDPClientState {
        switch state {
        case KRDP_STATE_CONNECTING: return .connecting
        case KRDP_STATE_CONNECTED: return .connected
        case KRDP_STATE_FAILED: return .failed(message ?? "connection failed")
        case KRDP_STATE_DISCONNECTED: return .disconnected(message)
        default: return .idle
        }
    }
}

/// Runs `body` with a C string for `value`, or with nil when `value` is nil/empty.
private func withOptionalCString<R>(_ value: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    guard let value, !value.isEmpty else { return body(nil) }
    return value.withCString(body)
}

/// Holds the Swift closures the C bridge calls back into. Retained via
/// `Unmanaged` for exactly as long as the C handle lives.
private final class RDPBridgeCallbacks {
    let onFrame: @Sendable (UnsafePointer<UInt8>?, Int, Int, Int) -> Void
    let onState: @Sendable (krdp_state, String?) -> Void

    init(
        onFrame: @escaping @Sendable (UnsafePointer<UInt8>?, Int, Int, Int) -> Void,
        onState: @escaping @Sendable (krdp_state, String?) -> Void
    ) {
        self.onFrame = onFrame
        self.onState = onState
    }
}

/// C function pointers cannot capture; they recover the Swift callbacks object
/// from the `user` pointer instead.
private func rdpFrameCallback(
    _ user: UnsafeMutableRawPointer?,
    _ bgra: UnsafePointer<UInt8>?,
    _ width: Int32,
    _ height: Int32,
    _ stride: Int32
) {
    guard let user else { return }
    let callbacks = Unmanaged<RDPBridgeCallbacks>.fromOpaque(user).takeUnretainedValue()
    callbacks.onFrame(bgra, Int(width), Int(height), Int(stride))
}

private func rdpStateCallback(
    _ user: UnsafeMutableRawPointer?,
    _ state: krdp_state,
    _ message: UnsafePointer<CChar>?
) {
    guard let user else { return }
    let callbacks = Unmanaged<RDPBridgeCallbacks>.fromOpaque(user).takeUnretainedValue()
    callbacks.onState(state, message.map { String(cString: $0) })
}

private extension RDPClient.MouseButton {
    /// Bit flags the C bridge expects.
    var cValue: Int32 {
        switch self {
        case .none: return 0
        case .left: return 1
        case .right: return 2
        case .middle: return 4
        }
    }
}
