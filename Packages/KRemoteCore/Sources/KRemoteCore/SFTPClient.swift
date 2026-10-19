import Foundation

/// One entry in a remote directory, as the UI needs it.
public struct RemoteEntry: Identifiable, Hashable, Sendable {
    /// The full absolute path, so a view can act on it without re-joining.
    public let path: String
    public let name: String
    public let attributes: SFTPAttributes

    public var id: String { path }
    public var isDirectory: Bool { attributes.isDirectory }
    public var isSymlink: Bool { attributes.isSymlink }
    public var size: UInt64? { attributes.size }
    public var modified: Date? { attributes.modified }
    public var permissions: UInt32? { attributes.permissions }

    public init(path: String, name: String, attributes: SFTPAttributes) {
        self.path = path
        self.name = name
        self.attributes = attributes
    }
}

/// Supplies a second, privileged transport when a normal operation is refused.
///
/// Card 6 implements this (`sudo -S -p '' <sftp-server>` with the stored
/// password). The client only defines the contract: given the failed
/// operation's path, return a transport already running as root, or nil to give
/// up and surface the original error.
public protocol ElevationProvider: AnyObject, Sendable {
    /// `nil` means "cannot elevate" — the caller then rethrows the permission
    /// error rather than looping.
    func elevatedTransport(for path: String) async -> SFTPTransport?
}

/// Speaks SFTP v3 over an injectable transport.
///
/// Requests are serialised: one in flight at a time, matched by request id. That
/// is enough for a file browser (a directory listing is a single round-trip) and
/// keeps the state machine small; pipelining can come later without changing the
/// API.
///
/// Every operation that can be refused by the server goes through
/// `perform`, which retries *once* on an elevated transport when the failure is
/// `permissionDenied` and an `ElevationProvider` is present.
public final class SFTPClient: @unchecked Sendable {
    private var transport: SFTPTransport
    private let elevation: ElevationProvider?
    /// Whether the current transport is already the elevated one. Elevation is
    /// attempted at most once per client, so a wrong password cannot loop.
    private var isElevated = false
    private var nextRequestID: UInt32 = 1
    private let lock = NSLock()
    private var readBuffer: [UInt8] = []
    private var serverVersion: UInt32 = 0
    private var isOpen = false

    public init(transport: SFTPTransport, elevation: ElevationProvider? = nil) {
        self.transport = transport
        self.elevation = elevation
    }

    public var version: UInt32 { lock.withLock { serverVersion } }

    /// The arguments of the running transport, for diagnostics.
    public var transportDescription: String {
        (transport as? ProcessSFTPTransport)?.commandLine.joined(separator: " ") ?? "custom transport"
    }

    // MARK: - Lifecycle

    /// Starts the subsystem and performs the version handshake.
    public func connect() async throws {
        try await transport.open()
        let initPacket = SFTPFraming.initPacket()
        try transport.write(initPacket)

        let packet = try await receive()
        guard packet.type == .version, let version = packet.version else {
            throw SFTPError.malformedPacket("expected VERSION, got \(packet.type)")
        }
        lock.withLock {
            serverVersion = version
            isOpen = true
        }
    }

    public func disconnect() {
        transport.close()
        lock.withLock { isOpen = false }
    }

    // MARK: - Requests

    /// Sends one request and returns its reply payload.
    private func request(type: SFTPPacketType, payload: [UInt8]) async throws -> SFTPFraming.Packet {
        guard lock.withLock({ isOpen }) else {
            throw SFTPError.connectionClosed("not connected")
        }
        let id = lock.withLock { () -> UInt32 in
            let current = nextRequestID
            nextRequestID = nextRequestID &+ 1
            return current
        }
        try transport.write(SFTPFraming.frame(type: type, id: id, payload: payload))

        // Replies arrive in order (one request in flight), but a stray packet for
        // an older id is discarded rather than mis-attributed.
        while true {
            let packet = try await receive()
            guard let packetID = packet.id else {
                throw SFTPError.malformedPacket("reply without an id")
            }
            if packetID == id { return packet }
        }
    }

    /// Reads one complete packet, buffering whatever the transport returns.
    private func receive() async throws -> SFTPFraming.Packet {
        while true {
            let buffered = lock.withLock { readBuffer }
            if let parsed = try SFTPFraming.parse(buffered) {
                lock.withLock { readBuffer.removeFirst(parsed.1) }
                return parsed.0
            }
            guard let chunk = try transport.read(maxLength: 64 * 1024) else {
                let reason = transport.stderrText().trimmingCharacters(in: .whitespacesAndNewlines)
                throw SFTPError.connectionClosed(reason.isEmpty ? "the server closed the connection" : reason)
            }
            lock.withLock { readBuffer.append(contentsOf: chunk) }
        }
    }

    /// Interprets a STATUS reply, throwing for anything but OK/EOF.
    private func checkStatus(_ packet: SFTPFraming.Packet, allowEOF: Bool = false) throws {
        guard packet.type == .status else {
            throw SFTPError.malformedPacket("expected STATUS, got \(packet.type)")
        }
        var reader = SFTPReader(packet.payload)
        let rawCode = try reader.uint32()
        guard let code = SFTPStatusCode(rawValue: rawCode) else {
            throw SFTPError.malformedPacket("unknown status code \(rawCode)")
        }
        let message = (try? reader.string()) ?? ""
        let language = (try? reader.string()) ?? ""
        let status = SFTPStatus(code: code, message: message, language: language)
        if status.isOK { return }
        if allowEOF, status.isEOF { return }
        throw SFTPError.status(status.code, message: status.message)
    }

    // MARK: - Elevation wrapper

    /// Runs `operation` on the current transport; on a permission failure, asks
    /// the elevation provider for a privileged transport and runs it once more.
    private func perform<T>(
        path: String,
        _ operation: (SFTPClient) async throws -> T
    ) async throws -> T {
        do {
            return try await operation(self)
        } catch SFTPError.status(let code, let message) where code == .permissionDenied {
            guard let elevation, !isElevated,
                  let elevated = await elevation.elevatedTransport(for: path) else {
                throw SFTPError.status(code, message: message)
            }
            try? await elevated.open()
            let privileged = SFTPClient(transport: elevated)
            privileged.isElevated = true
            try await privileged.handshake()
            defer { privileged.disconnect() }
            return try await operation(privileged)
        }
    }

    /// Version exchange on an already-started transport (used by the elevated
    /// client, whose `connect()` would spawn again).
    private func handshake() async throws {
        try transport.write(SFTPFraming.initPacket())
        let packet = try await receive()
        guard packet.type == .version, let version = packet.version else {
            throw SFTPError.malformedPacket("expected VERSION during elevation")
        }
        lock.withLock {
            serverVersion = version
            isOpen = true
        }
    }

    // MARK: - Paths

    /// Resolves a path to its absolute canonical form on the server.
    public func realpath(_ path: String) async throws -> String {
        let packet = try await request(type: .realpath, payload: SFTPRequests.pathOnly(Self.normalise(path)))
        switch packet.type {
        case .name:
            var reader = SFTPReader(packet.payload)
            let count = try reader.uint32()
            guard count >= 1 else {
                throw SFTPError.malformedPacket("REALPATH returned no names")
            }
            let filename = try reader.string()
            _ = try reader.string()          // longname
            _ = try reader.attributes()
            return filename
        case .status:
            try checkStatus(packet)
            throw SFTPError.malformedPacket("REALPATH answered with OK but no name")
        default:
            throw SFTPError.malformedPacket("unexpected reply \(packet.type) to REALPATH")
        }
    }

    // MARK: - Listing

    /// Lists a directory. `.` and `..` are dropped; the caller navigates locally.
    public func list(_ path: String) async throws -> [RemoteEntry] {
        let directory = Self.normalise(path)
        return try await perform(path: directory) { client in
            let openReply = try await client.request(
                type: .opendir,
                payload: SFTPRequests.pathOnly(directory)
            )
            guard openReply.type == .handle else {
                try client.checkStatus(openReply)
                throw SFTPError.malformedPacket("OPENDIR answered with \(openReply.type)")
            }
            var handleReader = SFTPReader(openReply.payload)
            let handle = try handleReader.rawData()
            defer { Task { try? await client.closeHandle(handle) } }

            var entries: [RemoteEntry] = []
            var finished = false
            while !finished {
                let reply = try await client.request(type: .readdir, payload: SFTPRequests.close(handle: handle))
                switch reply.type {
                case .name:
                    var reader = SFTPReader(reply.payload)
                    let count = try reader.uint32()
                    // A hostile server could claim a huge count; the reader would
                    // throw on the first missing byte anyway, but cap the loop.
                    for _ in 0..<min(count, 100_000) {
                        let filename = try reader.string()
                        let longname = try reader.string()
                        let attributes = try reader.attributes()
                        if filename == "." || filename == ".." { continue }
                        entries.append(
                            RemoteEntry(
                                path: Self.join(directory, filename),
                                name: filename,
                                attributes: attributes
                            )
                        )
                    }
                case .status:
                    try client.finishReaddir(reply)
                    finished = true
                default:
                    throw SFTPError.malformedPacket("unexpected reply \(reply.type) to READDIR")
                }
            }
            return entries.sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    /// EOF ends a directory listing; anything else is a real error.
    private func finishReaddir(_ packet: SFTPFraming.Packet) throws {
        var reader = SFTPReader(packet.payload)
        let rawCode = try reader.uint32()
        guard let code = SFTPStatusCode(rawValue: rawCode) else {
            throw SFTPError.malformedPacket("unknown status code \(rawCode)")
        }
        if code == .eof || code == .ok { return }
        throw SFTPError.status(code, message: (try? reader.string()) ?? "")
    }

    private func closeHandle(_ handle: [UInt8]) async throws {
        let reply = try await request(type: .close, payload: SFTPRequests.close(handle: handle))
        if reply.type == .status { try? checkStatus(reply) }
    }

    // MARK: - Metadata

    /// `stat` follows symlinks; `lstat` does not (so a link can be shown as one).
    public func stat(_ path: String, followSymlinks: Bool = true) async throws -> SFTPAttributes {
        let target = Self.normalise(path)
        return try await perform(path: target) { client in
            let reply = try await client.request(
                type: followSymlinks ? .stat : .lstat,
                payload: SFTPRequests.pathOnly(target)
            )
            guard reply.type == .attrs else {
                try client.checkStatus(reply)
                throw SFTPError.malformedPacket("STAT answered with \(reply.type)")
            }
            var reader = SFTPReader(reply.payload)
            return try reader.attributes()
        }
    }

    // MARK: - Reading / writing

    /// Downloads a whole file.
    public func readFile(_ path: String, progress: ((Int64, Int64?) -> Void)? = nil) async throws -> Data {
        let target = Self.normalise(path)
        return try await perform(path: target) { client in
            let size = (try? await client.stat(target))?.size
            let openReply = try await client.request(
                type: .open,
                payload: SFTPRequests.open(path: target, flags: .read)
            )
            guard openReply.type == .handle else {
                try client.checkStatus(openReply)
                throw SFTPError.malformedPacket("OPEN answered with \(openReply.type)")
            }
            var handleReader = SFTPReader(openReply.payload)
            let handle = try handleReader.rawData()
            defer { Task { try? await client.closeHandle(handle) } }

            var out = Data()
            var offset: UInt64 = 0
            while true {
                let reply = try await client.request(
                    type: .read,
                    payload: SFTPRequests.read(handle: handle, offset: offset, length: SFTPConstants.maxReadLength)
                )
                if reply.type == .status {
                    var reader = SFTPReader(reply.payload)
                    let code = try reader.uint32()
                    if code == SFTPStatusCode.eof.rawValue { break }
                    try client.checkStatus(reply)
                    continue
                }
                guard reply.type == .data else {
                    throw SFTPError.malformedPacket("unexpected reply \(reply.type) to READ")
                }
                var dataReader = SFTPReader(reply.payload)
                let chunk = try dataReader.rawData()
                if chunk.isEmpty { break }
                out.append(contentsOf: chunk)
                offset += UInt64(chunk.count)
                progress?(Int64(offset), size.map { Int64($0) })
            }
            return out
        }
    }

    /// Uploads `data` to `path`, creating or truncating it.
    public func writeFile(
        _ path: String,
        data: Data,
        progress: ((Int64, Int64) -> Void)? = nil
    ) async throws {
        let target = Self.normalise(path)
        try await perform(path: target) { client in
            let openReply = try await client.request(
                type: .open,
                payload: SFTPRequests.open(
                    path: target,
                    flags: [.write, .creat, .trunc],
                    attributes: SFTPAttributes(permissions: 0o644)
                )
            )
            guard openReply.type == .handle else {
                try client.checkStatus(openReply)
                throw SFTPError.malformedPacket("OPEN answered with \(openReply.type)")
            }
            var handleReader = SFTPReader(openReply.payload)
            let handle = try handleReader.rawData()
            defer { Task { try? await client.closeHandle(handle) } }

            let bytes = [UInt8](data)
            let chunkSize = Int(SFTPConstants.maxReadLength)
            var offset = 0
            while offset < bytes.count {
                let end = min(offset + chunkSize, bytes.count)
                let reply = try await client.request(
                    type: .write,
                    payload: SFTPRequests.write(
                        handle: handle,
                        offset: UInt64(offset),
                        data: Array(bytes[offset..<end])
                    )
                )
                try client.checkStatus(reply)
                offset = end
                progress?(Int64(offset), Int64(bytes.count))
            }
            _ = handle
        }
    }

    // MARK: - Mutations

    public func mkdir(_ path: String, permissions: UInt16 = 0o755) async throws {
        let target = Self.normalise(path)
        try await perform(path: target) { client in
            let reply = try await client.request(
                type: .mkdir,
                payload: SFTPRequests.mkdir(path: target, permissions: permissions)
            )
            try client.checkStatus(reply)
        }
    }

    public func remove(_ path: String) async throws {
        let target = Self.normalise(path)
        try await perform(path: target) { client in
            let reply = try await client.request(
                type: .remove,
                payload: SFTPRequests.pathOnly(target)
            )
            try client.checkStatus(reply)
        }
    }

    public func rmdir(_ path: String) async throws {
        let target = Self.normalise(path)
        try await perform(path: target) { client in
            let reply = try await client.request(
                type: .rmdir,
                payload: SFTPRequests.pathOnly(target)
            )
            try client.checkStatus(reply)
        }
    }

    public func rename(_ from: String, to: String) async throws {
        let source = Self.normalise(from)
        let destination = Self.normalise(to)
        try await perform(path: source) { client in
            let reply = try await client.request(
                type: .rename,
                payload: SFTPRequests.rename(from: source, to: destination)
            )
            try client.checkStatus(reply)
        }
    }

    /// chmod. `permissions` is the mode bits only (e.g. 0o755).
    public func setPermissions(_ path: String, permissions: UInt16) async throws {
        let target = Self.normalise(path)
        try await perform(path: target) { client in
            let reply = try await client.request(
                type: .setstat,
                payload: SFTPRequests.setstat(
                    path: target,
                    attributes: SFTPAttributes(permissions: UInt32(permissions & 0o7777))
                )
            )
            try client.checkStatus(reply)
        }
    }

    // MARK: - Path helpers

    /// Makes a path absolute and collapses `.`/`..` locally, so navigation never
    /// needs a server round-trip and `..` cannot escape the root.
    public static func normalise(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let absolute = trimmed.hasPrefix("/")
        var stack: [String] = []
        for component in trimmed.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..":
                if !stack.isEmpty { stack.removeLast() }
            default:
                stack.append(String(component))
            }
        }
        let joined = stack.joined(separator: "/")
        if absolute { return "/" + joined }
        return joined.isEmpty ? "." : joined
    }

    /// Joins a directory and a child name into an absolute path.
    public static func join(_ directory: String, _ name: String) -> String {
        let base = normalise(directory)
        if base == "/" { return "/" + name }
        return base + "/" + name
    }

    /// The parent of a path (`/a/b` → `/a`, `/a` → `/`, `/` → `/`).
    public static func parent(of path: String) -> String {
        let normalised = normalise(path)
        guard normalised != "/" else { return "/" }
        let parts = normalised.split(separator: "/").dropLast()
        return parts.isEmpty ? "/" : "/" + parts.joined(separator: "/")
    }
}
