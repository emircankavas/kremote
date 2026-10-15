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
///
/// Concurrency: FreeRDP runs the session on its own thread and calls back from
/// there. The callbacks therefore capture only `RDPBridgeSink` — a `@MainActor`
/// class, and so `Sendable` — and hand it an owned `Data` copy of the frame.
/// Nothing non-Sendable (this object, the `NSView`) crosses a thread boundary.
@MainActor
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

    private let sink: RDPBridgeSink
    private var handle: OpaquePointer?
    /// Last size handed to the server, so repeated `layout()` passes do not each
    /// send a resize.
    private var lastResizeSize: CGSize?
    /// Retained for the session's lifetime: the C side keeps only a raw pointer.
    private var callbacks: Unmanaged<RDPBridgeCallbacks>?

    init(onStateChange: @escaping @MainActor (RDPClientState) -> Void) {
        let sink = RDPBridgeSink()
        sink.onState = onStateChange
        self.sink = sink
        // Route credential requests to whoever set `onCredentialsNeeded`, and let
        // them answer by calling back into this client.
        sink.onCredentials = { [weak self] username, domain in
            guard let self else { return }
            self.onCredentialsNeeded?(username, domain) { [weak self] answer in
                self?.answerCredentials(answer)
            }
        }
        sink.onClipboard = { [weak self] text in
            self?.onRemoteClipboardText?(text)
        }
        sink.onClipboardFiles = { [weak self] paths in
            self?.onRemoteClipboardFiles?(paths)
        }
    }

    /// Called on the main actor when the server demands credentials the tree did
    /// not supply. The C session thread is blocked until the `answer` closure is
    /// invoked (which routes straight back into `answerCredentials`).
    var onCredentialsNeeded: (@MainActor (String, String, @escaping (RDPCredentialAnswer) -> Void) -> Void)?

    /// Called on the main actor with text the remote clipboard now holds.
    var onRemoteClipboardText: (@MainActor (String) -> Void)?

    /// Called on the main actor with files the remote clipboard now holds. Each
    /// path is an absolute local file the bridge has already downloaded into a
    /// temporary directory; the receiver is expected to put them on the
    /// pasteboard (as file URLs) so Finder can paste them.
    var onRemoteClipboardFiles: (@MainActor ([String]) -> Void)?

    /// Tells the server what the local clipboard holds, enabling paste inside the
    /// session. An empty string announces an empty clipboard.
    func setLocalClipboardText(_ text: String) {
        guard let handle else { return }
        text.withCString { krdp_client_set_clipboard(handle, $0) }
    }

    /// Announces the pasteboard's files to the server, so they can be pasted into
    /// the remote desktop. The bridge copies each path.
    func setLocalClipboardFiles(_ paths: [String]) {
        guard let handle else { return }
        if paths.isEmpty {
            krdp_client_set_clipboard_files(handle, nil, 0)
            return
        }
        // Owned C strings, only valid for this call (the bridge strdups them).
        var owned: [UnsafeMutablePointer<CChar>?] = paths.map { strdup($0) }
        defer { owned.forEach { free($0) } }
        var pointers: [UnsafePointer<CChar>?] = owned.map { UnsafePointer($0) }
        krdp_client_set_clipboard_files(handle, &pointers, Int32(paths.count))
    }

    /// Answers an outstanding credential request. Safe to call at any time.
    func answerCredentials(_ answer: RDPCredentialAnswer) {
        guard let handle else { return }
        switch answer {
        case .supply(let username, let domain, let password):
            username.withCString { user in
                domain.withCString { dom in
                    password.withCString { pw in
                        krdp_client_supply_credentials(handle, user, dom, pw)
                    }
                }
            }
        case .cancel:
            krdp_client_cancel_credentials(handle)
        }
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
            sink.deliverState(.failed("This build has no FreeRDP client library."))
            return
        }
        sink.view = view

        // The closures below run on FreeRDP's thread, so they capture only the
        // sink (a Sendable @MainActor object) plus values they copy.
        let sink = self.sink
        let callbacks = RDPBridgeCallbacks(
            onFrame: { bgra, width, height, stride in
                guard let bgra, width > 0, height > 0, stride > 0 else { return }
                // Build the CGImage *here*, on FreeRDP's thread, not on the main
                // actor: it is a per-frame allocation and copy of the whole
                // desktop, and doing it on main is what made a busy screen hitch.
                // Only the finished image crosses to the UI.
                guard let image = RDPClient.makeFrameImage(bgra, width: width, height: height, stride: stride) else { return }
                Task { @MainActor in sink.deliverFrameImage(image) }
            },
            onState: { state, message in
                let mapped = RDPClient.map(state: state, message: message)
                Task { @MainActor in sink.deliverState(mapped) }
            },
            onCredentials: { username, domain in
                // Runs on the session thread, which then blocks until answered;
                // hand the request to the main actor and return immediately.
                Task { @MainActor in sink.deliverCredentials(username: username, domain: domain) }
            },
            onClipboard: { text in
                // FreeRDP's buffer is freed once this returns, so copy it first.
                let copied = String(cString: text)
                Task { @MainActor in sink.deliverClipboard(copied) }
            },
            onClipboardFiles: { paths, count in
                // The C side's array and strings are freed once this returns;
                // copy them into Swift values first.
                var copied: [String] = []
                if let paths, count > 0 {
                    copied.reserveCapacity(count)
                    for i in 0..<count {
                        if let path = paths[i] { copied.append(String(cString: path)) }
                    }
                }
                Task { @MainActor in sink.deliverClipboardFiles(copied) }
            }
        )
        let retained = Unmanaged.passRetained(callbacks)
        self.callbacks = retained

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
                            rdpCredentialsCallback,
                            rdpClipboardCallback,
                            rdpClipboardFilesCallback,
                            pointer
                        )
                    }
                }
            }
        }
        guard let handle = created else {
            retained.release()
            self.callbacks = nil
            sink.deliverState(.failed("Could not create the RDP client."))
            return
        }

        self.handle = handle
        if !krdp_client_start(handle) {
            krdp_client_destroy(handle)
            self.handle = nil
            retained.release()
            self.callbacks = nil
            sink.deliverState(.failed("Could not start the RDP session."))
        }
    }

    func disconnect() {
        sink.view = nil
        if let handle {
            krdp_client_stop(handle)
            krdp_client_destroy(handle)
            self.handle = nil
        }
        callbacks?.release()
        callbacks = nil
    }

    func resize(to size: CGSize) {
        guard let handle, size.width > 0, size.height > 0 else { return }
        // `layout()` runs on every re-layout, and each call here sends a Display
        // Control resize to the server, which answers with a ResetGraphics that
        // tears down and rebuilds the graphics surfaces. Un-deduped that turns
        // ordinary relayouts into a visible hitch.
        guard size != lastResizeSize else { return }
        lastResizeSize = size
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

    /// Builds a CGImage from a FreeRDP BGRA frame, on the caller's thread.
    ///
    /// Two things matter for speed here, and both were wrong before:
    ///  * The bytes are tagged sRGB + premultiplied alpha. CoreAnimation takes a
    ///    CGImage's bytes as-is only for that exact combination; anything else
    ///    (device-RGB, skip-alpha) makes it convert through CoreGraphics on the
    ///    main thread *per frame*. FreeRDP does not promise the alpha byte, so it
    ///    is forced opaque during the copy, which also avoids a frame tagged
    ///    premultiplied-with-alpha-0 landing as an invisible desktop.
    ///  * It is built off the main thread — the copy alone is the size of the
    ///    whole desktop, every frame.
    nonisolated static func makeFrameImage(
        _ bgra: UnsafePointer<UInt8>, width: Int, height: Int, stride: Int
    ) -> CGImage? {
        let length = stride * height
        guard length > 0 else { return nil }
        guard let copy = malloc(length) else { return nil }
        let destination = copy.assumingMemoryBound(to: UInt32.self)
        let source = UnsafeRawPointer(bgra).assumingMemoryBound(to: UInt32.self)
        let words = length / 4
        for i in 0..<words { destination[i] = source[i] | 0xFF000000 }  // force alpha

        guard let provider = CGDataProvider(
            dataInfo: nil, data: copy, size: length,
            releaseData: { _, pointer, _ in free(UnsafeMutableRawPointer(mutating: pointer)) }
        ) else { free(copy); return nil }
        defer { }  // provider owns `copy` now

        let info = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        let colorSpace = sRGBColorSpace
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: stride, space: colorSpace, bitmapInfo: info,
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// Shared sRGB space; creating one per frame is needless work.
    nonisolated static let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        ?? CGColorSpaceCreateDeviceRGB()

    /// Pure mapping from the C enum; `nonisolated` and static so the callback
    /// does not have to capture anything from an instance.
    nonisolated static func map(state: krdp_state, message: String?) -> RDPClientState {
        switch state {
        case KRDP_STATE_CONNECTING: return .connecting
        case KRDP_STATE_CONNECTED: return .connected
        case KRDP_STATE_FAILED: return .failed(message ?? "connection failed")
        case KRDP_STATE_DISCONNECTED: return .disconnected(message)
        default: return .idle
        }
    }
}

/// Main-actor delivery target for frames and state.
///
/// A `@MainActor` class is `Sendable`, which is what lets FreeRDP's session
/// thread hold a reference to it and hop back to the main actor. Everything the
/// C callbacks touch lives here rather than on `RDPClient`.
@MainActor
final class RDPBridgeSink {
    weak var view: RDPHostView?
    var onState: ((RDPClientState) -> Void)?
    /// Set by `RDPClient`, which is the only thing that can route the answer back
    /// into the blocked session thread.
    var onCredentials: ((String, String) -> Void)?
    /// Text the remote clipboard now holds.
    var onClipboard: ((String) -> Void)?
    /// Files the remote clipboard now holds, already written to disk under a
    /// temporary directory the bridge owns.
    var onClipboardFiles: (([String]) -> Void)?

    func deliverFrameImage(_ image: CGImage) {
        view?.presentFrame(image)
    }

    func deliverState(_ state: RDPClientState) {
        onState?(state)
    }

    func deliverCredentials(username: String, domain: String) {
        onCredentials?(username, domain)
    }

    func deliverClipboard(_ text: String) {
        onClipboard?(text)
    }

    func deliverClipboardFiles(_ paths: [String]) {
        onClipboardFiles?(paths)
    }
}

/// Runs `body` with a C string for `value`, or with nil when `value` is nil/empty.
private func withOptionalCString<R>(_ value: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    guard let value, !value.isEmpty else { return body(nil) }
    return value.withCString(body)
}

/// Holds the closures the C bridge calls back into. Retained via `Unmanaged` for
/// exactly as long as the C handle lives; both closures are `@Sendable` and
/// capture only Sendable state.
private final class RDPBridgeCallbacks: Sendable {
    let onFrame: @Sendable (UnsafePointer<UInt8>?, Int, Int, Int) -> Void
    let onState: @Sendable (krdp_state, String?) -> Void
    let onCredentials: @Sendable (String, String) -> Void
    let onClipboard: @Sendable (UnsafePointer<CChar>) -> Void
    let onClipboardFiles: @Sendable (UnsafePointer<UnsafePointer<CChar>?>?, Int) -> Void

    init(
        onFrame: @escaping @Sendable (UnsafePointer<UInt8>?, Int, Int, Int) -> Void,
        onState: @escaping @Sendable (krdp_state, String?) -> Void,
        onCredentials: @escaping @Sendable (String, String) -> Void,
        onClipboard: @escaping @Sendable (UnsafePointer<CChar>) -> Void,
        onClipboardFiles: @escaping @Sendable (UnsafePointer<UnsafePointer<CChar>?>?, Int) -> Void
    ) {
        self.onFrame = onFrame
        self.onState = onState
        self.onCredentials = onCredentials
        self.onClipboard = onClipboard
        self.onClipboardFiles = onClipboardFiles
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

private func rdpCredentialsCallback(
    _ user: UnsafeMutableRawPointer?,
    _ username: UnsafePointer<CChar>?,
    _ domain: UnsafePointer<CChar>?
) {
    guard let user else { return }
    let callbacks = Unmanaged<RDPBridgeCallbacks>.fromOpaque(user).takeUnretainedValue()
    callbacks.onCredentials(
        username.map { String(cString: $0) } ?? "",
        domain.map { String(cString: $0) } ?? ""
    )
}

private func rdpClipboardCallback(
    _ user: UnsafeMutableRawPointer?,
    _ utf8: UnsafePointer<CChar>?
) {
    guard let user, let utf8 else { return }
    let callbacks = Unmanaged<RDPBridgeCallbacks>.fromOpaque(user).takeUnretainedValue()
    callbacks.onClipboard(utf8)
}

private func rdpClipboardFilesCallback(
    _ user: UnsafeMutableRawPointer?,
    _ paths: UnsafePointer<UnsafePointer<CChar>?>?,
    _ count: Int32
) {
    guard let user else { return }
    let callbacks = Unmanaged<RDPBridgeCallbacks>.fromOpaque(user).takeUnretainedValue()
    callbacks.onClipboardFiles(paths, Int(count))
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
