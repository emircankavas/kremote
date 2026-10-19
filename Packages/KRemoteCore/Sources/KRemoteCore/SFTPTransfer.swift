import Foundation

// MARK: - Progress and cancellation

/// One progress tick for a transfer.
///
/// `bytesTotal` is nil when the size could not be known up front (a server that
/// refuses STAT, or a stream that grows while it is read); the UI then shows
/// bytes and throughput without a bar.
public struct TransferProgress: Sendable, Equatable {
    public var bytesDone: Int64
    public var bytesTotal: Int64?

    public init(bytesDone: Int64, bytesTotal: Int64? = nil) {
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
    }

    /// 0…1 when the total is known, else nil.
    public var fraction: Double? {
        guard let bytesTotal, bytesTotal > 0 else { return nil }
        return min(1, max(0, Double(bytesDone) / Double(bytesTotal)))
    }
}

/// Thrown by a transfer that the user cancelled.
///
/// Deliberately its own type, not an `SFTPError`: cancelling is not a protocol
/// failure, and the caller has cleanup to do (delete the `.part` file) that a
/// server error does not imply.
public struct TransferCancelled: Error, Sendable, Equatable {
    public init() {}
}

extension TransferCancelled: LocalizedError {
    public var errorDescription: String? { "Transfer cancelled" }
}

// MARK: - Transfers

/// Streaming file transfer and recursive operations.
///
/// Everything here is chunked: a 200 MB file never lands in memory, and the
/// remote handle is closed on every exit path — success, server error and
/// cancellation alike. Cancellation is polled between chunks, which is what the
/// window's Cancel button drives.
///
/// All of it goes through `perform`, so a refused root-owned path is retried
/// once over the elevated channel exactly like every other operation.
extension SFTPClient {

    /// Downloads one file into `localURL`, which only appears once the transfer
    /// has finished.
    ///
    /// The bytes go to `localURL.part` and are renamed into place on the last
    /// chunk, so a cancelled or failed download never leaves a half file that
    /// looks complete — and the `.part` file is deleted on every exit path.
    @discardableResult
    public func downloadFile(
        _ remotePath: String,
        to localURL: URL,
        progress: (@Sendable (TransferProgress) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) async throws -> Int64 {
        let target = Self.normalise(remotePath)
        let partURL = Self.partURL(for: localURL)
        do {
            let written = try await downloadChunks(
                target, to: partURL, progress: progress, isCancelled: isCancelled
            )
            // Replace, don't merge: the window asked the user about a conflict
            // already, and a stale file left behind would be worse than none.
            if FileManager.default.fileExists(atPath: localURL.path) {
                try FileManager.default.removeItem(at: localURL)
            }
            try FileManager.default.moveItem(at: partURL, to: localURL)
            return written
        } catch {
            Self.removeQuietly(partURL)
            throw error
        }
    }

    /// The streaming half of a download. Writes `partURL` verbatim.
    private func downloadChunks(
        _ target: String,
        to partURL: URL,
        progress: (@Sendable (TransferProgress) -> Void)?,
        isCancelled: (@Sendable () -> Bool)?
    ) async throws -> Int64 {
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

            // The remote handle is closed on every path, including a cancel or
            // a dead transport: a server holds an open file until CLOSE arrives.
            var closed = false
            do {
                if FileManager.default.fileExists(atPath: partURL.path) {
                    try FileManager.default.removeItem(at: partURL)
                }
                guard FileManager.default.createFile(atPath: partURL.path, contents: nil) else {
                    throw SFTPError.transport("could not create \(partURL.path)")
                }
                let file = try FileHandle(forWritingTo: partURL)
                defer { try? file.close() }

                var offset: UInt64 = 0
                while true {
                    if isCancelled?() == true {
                        try? await client.closeHandle(handle)
                        closed = true
                        throw TransferCancelled()
                    }
                    let reply = try await client.request(
                        type: .read,
                        payload: SFTPRequests.read(
                            handle: handle, offset: offset, length: SFTPConstants.maxReadLength
                        )
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
                    try file.write(contentsOf: Data(chunk))
                    offset += UInt64(chunk.count)
                    progress?(TransferProgress(
                        bytesDone: Int64(offset),
                        bytesTotal: size.map { Int64($0) }
                    ))
                }
                try await client.closeHandle(handle)
                closed = true
                return Int64(offset)
            } catch {
                if !closed { try? await client.closeHandle(handle) }
                throw error
            }
        }
    }

    /// Uploads one local file to `remotePath`, which only appears complete.
    ///
    /// The bytes go to a `.part` name beside the target and are RENAMEd over it
    /// when the last chunk is acknowledged, so a cancelled upload leaves nothing
    /// under the real name and the `.part` is removed on every exit path.
    @discardableResult
    public func uploadFile(
        _ localURL: URL,
        to remotePath: String,
        progress: (@Sendable (TransferProgress) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) async throws -> Int64 {
        let target = Self.normalise(remotePath)
        let partPath = Self.remotePartPath(target)
        // Fail on an unreadable local file before touching the server: a missing
        // source should not create and then delete a temp file on the remote side.
        _ = try FileManager.default.attributesOfItem(atPath: localURL.path)
        do {
            let written = try await uploadChunks(
                localURL, to: partPath, progress: progress, isCancelled: isCancelled
            )
            try await rename(partPath, to: target)
            return written
        } catch {
            try? await remove(partPath)
            throw error
        }
    }

    /// The streaming half of an upload. Writes `target` verbatim.
    private func uploadChunks(
        _ localURL: URL,
        to target: String,
        progress: (@Sendable (TransferProgress) -> Void)?,
        isCancelled: (@Sendable () -> Bool)?
    ) async throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let reader = try FileHandle(forReadingFrom: localURL)
        defer { try? reader.close() }

        return try await perform(path: target) { client in
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

            var closed = false
            do {
                var offset: UInt64 = 0
                while true {
                    if isCancelled?() == true {
                        try? await client.closeHandle(handle)
                        closed = true
                        throw TransferCancelled()
                    }
                    let chunk = try reader.read(upToCount: Int(SFTPConstants.maxReadLength)) ?? Data()
                    if chunk.isEmpty { break }
                    let reply = try await client.request(
                        type: .write,
                        payload: SFTPRequests.write(
                            handle: handle, offset: offset, data: [UInt8](chunk)
                        )
                    )
                    try client.checkStatus(reply)
                    offset += UInt64(chunk.count)
                    progress?(TransferProgress(bytesDone: Int64(offset), bytesTotal: size))
                }
                try await client.closeHandle(handle)
                closed = true
                return Int64(offset)
            } catch {
                if !closed { try? await client.closeHandle(handle) }
                throw error
            }
        }
    }

    // MARK: - Recursive

    /// Every entry under `path` (files, directories, links), depth first.
    ///
    /// `isDirectory` comes from LSTAT so a symlink to a directory is *not*
    /// walked — following links could loop forever or escape the folder the user
    /// asked to delete.
    public func walk(_ path: String) async throws -> [RemoteEntry] {
        let root = Self.normalise(path)
        var collected: [RemoteEntry] = []
        try await walk(root, into: &collected)
        return collected
    }

    private func walk(_ directory: String, into collected: inout [RemoteEntry]) async throws {
        let children = try await list(directory)
        for child in children {
            let attributes = (try? await stat(child.path, followSymlinks: false)) ?? child.attributes
            let entry = RemoteEntry(path: child.path, name: child.name, attributes: attributes)
            collected.append(entry)
            if entry.isDirectory && !entry.isSymlink {
                try await walk(child.path, into: &collected)
            }
        }
    }

    /// How many entries a delete would remove, for the confirmation text.
    /// Directories count themselves, so deleting a folder with 3 files says 4.
    public func countItems(in path: String) async throws -> Int {
        (try await walk(path)).count
    }

    /// Deletes a file, a symlink, or a whole directory tree.
    ///
    /// SFTP v3 has no recursive delete, so this lists and removes depth first,
    /// deepest entries first, then rmdirs the directory itself. Returns the
    /// number of entries removed, which the batch summary reports.
    @discardableResult
    public func removeRecursively(_ path: String) async throws -> Int {
        let target = Self.normalise(path)
        let attributes = try await stat(target, followSymlinks: false)
        guard attributes.isDirectory, !attributes.isSymlink else {
            try await remove(target)
            return 1
        }
        let children = try await list(target)
        var removed = 0
        for child in children {
            let childAttributes = (try? await stat(child.path, followSymlinks: false)) ?? child.attributes
            if childAttributes.isDirectory && !childAttributes.isSymlink {
                removed += try await removeRecursively(child.path)
            } else {
                try await remove(child.path)
                removed += 1
            }
        }
        try await rmdir(target)
        return removed + 1
    }

    /// Total bytes of every regular file under a directory (or the size of one
    /// file). Used to give a tree transfer a real total instead of a spinner.
    public func totalSize(of path: String) async throws -> Int64 {
        let attributes = try await stat(path, followSymlinks: false)
        guard attributes.isDirectory, !attributes.isSymlink else {
            return Int64(attributes.size ?? 0)
        }
        var total: Int64 = 0
        for entry in try await walk(path) where !entry.isDirectory {
            total += Int64(entry.size ?? 0)
        }
        return total
    }

    /// Downloads a directory tree into `localDirectory`, which is created.
    ///
    /// `relativeTo` maps a remote entry onto a local one; the root folder's own
    /// name is supplied by the caller as the last component of
    /// `localDirectory`, so a download of `/srv/www` to `/Users/x/Downloads/www`
    /// preserves the tree below `www`.
    @discardableResult
    public func downloadTree(
        _ remotePath: String,
        to localDirectory: URL,
        progress: (@Sendable (TransferProgress) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) async throws -> Int64 {
        let root = Self.normalise(remotePath)
        let entries = try await walk(root)
        let total = entries.reduce(Int64(0)) { $0 + ($1.isDirectory ? 0 : Int64($1.size ?? 0)) }
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)

        var done: Int64 = 0
        for entry in entries {
            if isCancelled?() == true { throw TransferCancelled() }
            let relative = Self.relativeComponents(of: entry.path, under: root).joined(separator: "/")
            let destination = relative.isEmpty
                ? localDirectory
                : localDirectory.appendingPathComponent(relative)
            if entry.isDirectory {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                continue
            }
            // A symlink is copied as its target's bytes: creating remote links is
            // out of scope for 1.8.0, and a browser that silently drops them is
            // worse than one that copies the content.
            let base = done
            try await downloadFile(entry.path, to: destination, progress: { tick in
                progress?(TransferProgress(bytesDone: base + tick.bytesDone, bytesTotal: total))
            }, isCancelled: isCancelled)
            done += Int64(entry.size ?? 0)
            progress?(TransferProgress(bytesDone: done, bytesTotal: total))
        }
        if entries.isEmpty {
            progress?(TransferProgress(bytesDone: 0, bytesTotal: 0))
        }
        return done
    }

    /// Uploads a local directory tree to `remotePath`, creating directories as
    /// it goes.
    @discardableResult
    public func uploadTree(
        from localDirectory: URL,
        to remotePath: String,
        progress: (@Sendable (TransferProgress) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) async throws -> Int64 {
        let root = Self.normalise(remotePath)
        let files = try Self.walkLocal(localDirectory)
        let total = files.reduce(Int64(0)) { $0 + $1.size }

        try await mkdir(root)
        var createdDirectories: Set<String> = []
        var done: Int64 = 0
        for file in files {
            if isCancelled?() == true { throw TransferCancelled() }
            let suffix = file.relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !suffix.isEmpty else { throw SFTPError.invalidArgument("empty relative path for \(file.url.lastPathComponent)") }
            let remoteFile = Self.join(root, suffix)
            let remoteDirectory = Self.parent(of: remoteFile)
            if remoteDirectory != root, !createdDirectories.contains(remoteDirectory) {
                try await Self.makeDirectories(remoteDirectory, relativeTo: root, client: self)
                createdDirectories.insert(remoteDirectory)
            }
            let base = done
            try await uploadFile(file.url, to: remoteFile, progress: { tick in
                progress?(TransferProgress(bytesDone: base + tick.bytesDone, bytesTotal: total))
            }, isCancelled: isCancelled)
            done += file.size
            progress?(TransferProgress(bytesDone: done, bytesTotal: total))
        }
        return done
    }

    /// Creates `path` (a descendant of `root`) directory by directory, ignoring
    /// "already exists" so a resumed tree upload does not fail on its own work.
    private static func makeDirectories(_ path: String, relativeTo root: String, client: SFTPClient) async throws {
        var current = root
        let suffix = path.dropFirst(root.count).split(separator: "/").map(String.init)
        for component in suffix {
            current = current == "/" ? "/" + component : current + "/" + component
            do {
                try await client.mkdir(current)
            } catch SFTPError.status(let code, _) where code == .failure || code == .permissionDenied {
                // "Failure" is what OpenSSH returns for an existing directory;
                // a real permission problem resurfaces on the upload itself.
                if (try? await client.stat(current))?.isDirectory != true { throw SFTPError.status(code, message: current) }
            }
        }
    }

    // MARK: - Ownership

    /// chown. `nil` leaves that half unchanged.
    ///
    /// SFTP v3 carries uid and gid in one flag, so a request with only a uid
    /// still has to send a gid — the current one is read first and kept.
    public func setOwner(_ path: String, uid: UInt32?, gid: UInt32?) async throws {
        let target = Self.normalise(path)
        try await perform(path: target) { client in
            var effectiveUID = uid
            var effectiveGID = gid
            if effectiveUID == nil || effectiveGID == nil {
                let current = try await client.stat(target)
                if effectiveUID == nil { effectiveUID = current.uid }
                if effectiveGID == nil { effectiveGID = current.gid }
            }
            guard let effectiveUID, let effectiveGID else {
                throw SFTPError.invalidArgument("the server did not report the current owner")
            }
            let reply = try await client.request(
                type: .setstat,
                payload: SFTPRequests.setstat(
                    path: target,
                    attributes: SFTPAttributes(uid: effectiveUID, gid: effectiveGID)
                )
            )
            try client.checkStatus(reply)
        }
    }

    /// chmod and chown in one SETSTAT, so a permissions sheet applies atomically.
    public func setAttributes(
        _ path: String,
        permissions: UInt16?,
        uid: UInt32?,
        gid: UInt32?
    ) async throws {
        let target = Self.normalise(path)
        try await perform(path: target) { client in
            var attributes = SFTPAttributes()
            if let permissions { attributes.permissions = UInt32(permissions & 0o7777) }
            if uid != nil || gid != nil {
                var effectiveUID = uid
                var effectiveGID = gid
                if effectiveUID == nil || effectiveGID == nil {
                    let current = try await client.stat(target)
                    if effectiveUID == nil { effectiveUID = current.uid }
                    if effectiveGID == nil { effectiveGID = current.gid }
                }
                guard let effectiveUID, let effectiveGID else {
                    throw SFTPError.invalidArgument("the server did not report the current owner")
                }
                attributes.uid = effectiveUID
                attributes.gid = effectiveGID
            }
            guard attributes.permissions != nil || attributes.uid != nil else { return }
            let reply = try await client.request(
                type: .setstat,
                payload: SFTPRequests.setstat(path: target, attributes: attributes)
            )
            try client.checkStatus(reply)
        }
    }

    // MARK: - Local helpers

    /// The `.part` sibling of a local target. Kept next to the target, not in
    /// /tmp, so the final rename is a same-volume move and cannot half-copy.
    ///
    /// Public because it is part of the transfer's contract: a cancelled download
    /// leaves nothing here, and a caller that wants to show the temporary file (or
    /// clean up after a crash) needs the same name this code uses.
    public static func partURL(for url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).part")
    }

    /// The `.part` sibling of a remote target, hidden so a listing does not show
    /// a transfer in progress next to a file of the same name.
    ///
    /// Kept relative when the target is relative: `parent(of:)` normalises to an
    /// absolute path, which would silently move the temporary file to `/` and
    /// leave the real target never created.
    static func remotePartPath(_ path: String) -> String {
        let normalised = normalise(path)
        let name = (normalised as NSString).lastPathComponent
        let partName = ".\(name).part"
        guard normalised.hasPrefix("/") else {
            let directory = (normalised as NSString).deletingLastPathComponent
            return directory.isEmpty || directory == "." ? partName : directory + "/" + partName
        }
        return join(parent(of: normalised), partName)
    }

    /// Removes a local file if it is there, never throwing: this runs on cleanup
    /// paths where the original error is the one worth reporting.
    static func removeQuietly(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// `["a", "b", "two.txt"]` for `/srv/tree` under `/srv`; `[]` for the root itself.
    ///
    /// Done by comparing components rather than string prefixes: a caller's path
    /// may have gone through a symlink (`/tmp` → `/private/tmp` on macOS), and
    /// `dropFirst(root.count)` silently produces a truncated name when the two
    /// strings disagree about that. It returns nil-ish ([]) instead of a wrong path.
    static func relativeComponents(of path: String, under root: String) -> [String] {
        let child = normalise(path).split(separator: "/").map(String.init)
        let parent = normalise(root).split(separator: "/").map(String.init)
        guard child.count >= parent.count, Array(child.prefix(parent.count)) == parent else {
            // Not under this root at all: use the last component rather than
            // inventing a path, so a file still lands in a folder of its own name.
            return child.last.map { [$0] } ?? []
        }
        return Array(child.dropFirst(parent.count))
    }

    /// Whether `path` is inside `root` (or is `root` itself).
    static func isInside(_ path: String, root: String) -> Bool {
        let child = normalise(path).split(separator: "/").map(String.init)
        let parent = normalise(root).split(separator: "/").map(String.init)
        return child.count >= parent.count && Array(child.prefix(parent.count)) == parent
    }

    struct LocalFile {
        let url: URL
        /// The path below the walked root, always starting with `/`.
        let relativePath: String
        let size: Int64
    }

    /// Every regular file under `root`, depth first, symlinks skipped.
    ///
    /// The relative path is taken from the enumerator's own URLs, not by trimming a
    /// fixed prefix off `url.path`: on macOS the returned URLs may be resolved
    /// through a symlink (`/tmp` → `/private/tmp`), and a length-based trim then
    /// produces a mangled name — a real bug the live round trip caught, where the
    /// tree landed in `/tmp/kremote-t6ff-live/ff-tree` instead of `tree-upload`.
    static func walkLocal(_ root: URL) throws -> [LocalFile] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else {
            throw SFTPError.invalidArgument("could not read \(root.path)")
        }
        let rootComponents = root.standardizedFileURL.resolvingSymlinksInPath()
            .pathComponents
            .filter { $0 != "/" }
        var files: [LocalFile] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isDirectory == true || values.isSymbolicLink == true { continue }
            let components = url.standardizedFileURL.pathComponents.filter { $0 != "/" }
            // Walk the file's components past the root's, so a resolved symlink
            // prefix simply matches what the enumerator reported.
            var start = 0
            while start < rootComponents.count, start < components.count,
                  components[start] == rootComponents[start] {
                start += 1
            }
            let suffix = "/" + components.dropFirst(start).joined(separator: "/")
            files.append(LocalFile(url: url, relativePath: suffix, size: Int64(values.fileSize ?? 0)))
        }
        return files
    }
}
