import Foundation

/// Reads and writes the connection tree as JSON.
///
/// The on-disk envelope carries a schema `version` so a later format change can
/// migrate instead of failing to decode. Passwords never appear here — only
/// `AppModel` moves those in and out of the `SecretStore`.
public final class NodeStore {
    public static let currentVersion = 1

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    private struct Envelope: Codable {
        var version: Int
        var roots: [ConnectionNode]
    }

    /// Returns nil when no file exists yet, so the caller can decide whether to
    /// seed first-run content.
    public func load() throws -> [ConnectionNode]? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        return envelope.roots
    }

    public func save(_ roots: [ConnectionNode]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Envelope(version: Self.currentVersion, roots: roots))
        try data.write(to: fileURL, options: .atomic)
    }

    /// True when the file exists and decodes.
    public var exists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }
}

extension NodeStore {
    /// `~/Library/Application Support/KRemote/tree.json`
    public static func defaultFileURL() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("KRemote", isDirectory: true)
            .appendingPathComponent("tree.json")
    }

    public static func defaultStore() -> NodeStore {
        NodeStore(fileURL: defaultFileURL())
    }
}
