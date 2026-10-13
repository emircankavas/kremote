import Foundation
import NIOCore
import NIOSSH

/// Trust-on-first-use store for SSH host keys.
///
/// mRemoteNG-style managers usually keep their own known-hosts. We record the
/// host key the first time we connect and refuse to connect later if it changes —
/// which is the protection that matters (a changed key means a possible MITM).
///
/// A first connection is accepted and recorded automatically. A user-facing
/// "unknown host key, accept?" prompt is a future refinement; the mismatch check
/// below already closes the dangerous case.
public struct KnownHostsStore {
    public struct Entry: Codable, Equatable {
        public var key: String
    }

    public let fileURL: URL
    private var entries: [String: Entry]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.entries = (try? Self.read(fileURL)) ?? [:]
    }

    public static func defaultFileURL() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("KRemote", isDirectory: true)
            .appendingPathComponent("known_hosts.json")
    }

    public static func defaultStore() -> KnownHostsStore {
        KnownHostsStore(fileURL: defaultFileURL())
    }

    private static func hostKey(host: String, port: Int) -> String {
        "\(host.lowercased()):\(port)"
    }

    public func recordedKey(host: String, port: Int) -> String? {
        entries[Self.hostKey(host: host, port: port)]?.key
    }

    public mutating func record(key: String, host: String, port: Int) throws {
        entries[Self.hostKey(host: host, port: port)] = Entry(key: key)
        try Self.write(entries, to: fileURL)
    }

    // MARK: - Disk

    private static func read(_ url: URL) throws -> [String: Entry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: url))
    }

    private static func write(_ entries: [String: Entry], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: url, options: .atomic)
    }
}

extension KnownHostsStore {
    /// A stable, copyable representation of a host key (the OpenSSH wire encoding,
    /// base64). Not byte-for-byte the `ssh-keyscan` line — it lacks the
    /// `ssh-ed25519` prefix — but stable across runs, which is all TOFU needs.
    public static func encode(_ key: NIOSSHPublicKey) -> String {
        var buffer = ByteBufferAllocator().buffer(capacity: 0)
        key.write(to: &buffer)
        return Data(buffer.readableBytesView).base64EncodedString()
    }
}

/// NIOSSH host-key validator that trusts the first key seen and rejects changes.
public final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let host: String
    private let port: Int
    private let storeURL: URL
    private let lock = NSLock()

    public init(host: String, port: Int, storeURL: URL = KnownHostsStore.defaultFileURL()) {
        self.host = host
        self.port = port
        self.storeURL = storeURL
    }

    public func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        lock.lock()
        defer { lock.unlock() }

        let encoded = KnownHostsStore.encode(hostKey)
        var store = KnownHostsStore(fileURL: storeURL)

        if let recorded = store.recordedKey(host: host, port: port) {
            if recorded == encoded {
                validationCompletePromise.succeed(())
            } else {
                // Key changed under the same host:port — refuse.
                validationCompletePromise.fail(KnownHostsError.keyChanged(host: host, port: port))
            }
            return
        }

        // First contact: record and trust.
        do {
            try store.record(key: encoded, host: host, port: port)
            validationCompletePromise.succeed(())
        } catch {
            validationCompletePromise.fail(error)
        }
    }
}

public enum KnownHostsError: Error, CustomStringConvertible {
    case keyChanged(host: String, port: Int)

    public var description: String {
        switch self {
        case .keyChanged(let host, let port):
            return "Host key for \(host):\(port) changed since the last connection. "
                + "This can indicate a man-in-the-middle attack. Connection refused."
        }
    }
}
