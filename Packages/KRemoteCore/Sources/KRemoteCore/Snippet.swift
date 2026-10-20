import Foundation

/// A saved script the user can run on a connected server.
///
/// A snippet is a name, a body and nothing else: no shell, no working directory, no
/// environment. Each of those would be a per-host setting the user has to keep in
/// sync, and the script itself can `cd` or export what it needs — which is what a
/// script is for.
public struct Snippet: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    /// Shown in the menu; also the first line of the confirmation.
    public var name: String
    /// The script body. Run by the server's `sh`, not pasted into the terminal.
    public var body: String
    /// Ordering hint for the menu; ties fall back to the name.
    public var sortIndex: Int

    public init(id: UUID = UUID(), name: String, body: String, sortIndex: Int = 0) {
        self.id = id
        self.name = name
        self.body = body
        self.sortIndex = sortIndex
    }

    /// Whether the body would run at all. An empty snippet is a menu entry that
    /// does nothing, which reads as a bug.
    public var isRunnable: Bool {
        !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Every snippet, in menu order.
public enum SnippetLibrary {

    /// Portable shell used to decode and run the script.
    ///
    /// `base64 -d` is the spelling both GNU and BSD accept; macOS's `-D` is the odd
    /// one out, so `-d` is what ships. Verified on macOS 26 (BSD) and on Linux.
    public static let decoder = "base64 -d"

    /// The command that runs `snippet` on a POSIX server.
    ///
    /// Design notes, because this is the part that can go wrong:
    ///
    /// - **The body never touches the terminal's input buffer.** Pasting a
    ///   multi-line script into a pty makes the shell execute it line by line as it
    ///   arrives, which mangles anything with quotes, heredocs or `if` blocks and
    ///   makes a partial run impossible to abort.
    /// - **It is base64, not quoted.** A script can contain any byte; wrapping it in
    ///   single quotes breaks on the first `'` and escaping every case is a bug
    ///   waiting to happen. Base64 has no characters the shell treats specially.
    /// - **The file is removed even on failure**, by `trap`, so a failed run does not
    ///   leave an executable copy of the user's script on a shared server.
    public static func command(for snippet: Snippet) -> String {
        let encoded = Data(snippet.body.utf8).base64EncodedString()
        // `$$` is the shell's own pid, so two snippets run at once cannot collide.
        let path = "/tmp/kremote-snippet-$$.sh"
        return [
            "f=\"\(path)\"",
            "printf '%s' '\(encoded)' | \(decoder) > \"$f\"",
            "sh \"$f\"",
            "rc=$?",
            "rm -f \"$f\"",
            "exit $rc",
        ].joined(separator: "; ")
    }

    /// One line, for the confirmation dialog.
    ///
    /// Shows the body's own first lines rather than a summary: the user is about to
    /// run a script, and the thing worth confirming is the script.
    public static func preview(of snippet: Snippet, maximumLines: Int = 12) -> String {
        let body = snippet.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = body.components(separatedBy: "\n")
        if lines.count <= maximumLines { return body }
        return lines.prefix(maximumLines).joined(separator: "\n")
            + "\n… \(lines.count - maximumLines) more lines"
    }

    /// Whether a snippet is destructive enough to deserve a heavier warning.
    ///
    /// Never a substitute for the confirmation — every run is confirmed — but "this
    /// deletes things" is worth saying differently from "this lists a directory".
    public static func isDestructive(_ snippet: Snippet) -> Bool {
        let text = snippet.body.lowercased()
        let patterns = [
            "rm -rf", "rm -fr", "mkfs", "> /dev/sd", "dd if=", "shutdown", "reboot",
            "halt", "init 0", "init 6", "truncate", "chmod -r 777", "drop database",
            "drop table", "killall", "pkill -9",
        ]
        return patterns.contains { text.contains($0) }
    }
}

/// Reads and writes the snippet list as JSON.
///
/// Separate from the connection tree: snippets belong to the user, not to a host, and
/// keeping them in their own file means a corrupted tree cannot take them with it.
public final class SnippetStore {
    public static let currentVersion = 1

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    private struct Envelope: Codable {
        var version: Int
        var snippets: [Snippet]
    }

    /// nil when no file exists yet, so the caller can decide about defaults.
    public func load() throws -> [Snippet]? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        return envelope.snippets
    }

    public func save(_ snippets: [Snippet]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        // Sorted keys keep the file diffable; a snippet library is something a user
        // may well keep in version control.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Envelope(version: Self.currentVersion, snippets: snippets))
        try data.write(to: fileURL, options: .atomic)
    }
}

extension SnippetStore {
    /// `~/Library/Application Support/KRemote/snippets.json`
    public static func defaultFileURL() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("KRemote", isDirectory: true)
            .appendingPathComponent("snippets.json")
    }

    public static func defaultStore() -> SnippetStore {
        SnippetStore(fileURL: defaultFileURL())
    }
}
