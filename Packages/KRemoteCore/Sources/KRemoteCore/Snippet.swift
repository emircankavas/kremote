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
    /// Values the script expects, shown before it runs.
    ///
    /// Variables rather than positional arguments: a script written as
    /// `$TARGET_HOST` is readable on its own, while `$3` means nothing without the
    /// caller's ordering in mind.
    public var parameters: [SnippetParameter]

    public init(
        id: UUID = UUID(),
        name: String,
        body: String,
        sortIndex: Int = 0,
        parameters: [SnippetParameter] = []
    ) {
        self.id = id
        self.name = name
        self.body = body
        self.sortIndex = sortIndex
        self.parameters = parameters
    }

    // Decoded leniently: a snippets.json written before parameters existed has no
    // such key, and losing a whole library over a missing array would be absurd.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        body = try container.decode(String.self, forKey: .body)
        sortIndex = try container.decodeIfPresent(Int.self, forKey: .sortIndex) ?? 0
        parameters = try container.decodeIfPresent([SnippetParameter].self, forKey: .parameters) ?? []
    }

    /// Whether the body would run at all. An empty snippet is a menu entry that
    /// does nothing, which reads as a bug.
    public var isRunnable: Bool {
        !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Parameters that must be filled in before the script can run.
    public var requiredParameters: [SnippetParameter] {
        parameters.filter { $0.isRequired }
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
    /// Every detail here was decided by running it in a real pty, because the app
    /// writes into an *interactive login shell* and that changes what each part means:
    ///
    /// - **Wrapped in parentheses.** A bare `exit $rc` at the end does not report a
    ///   status in an interactive shell — it terminates the shell, and the ssh session
    ///   with it. Inside parentheses `exit` ends only the subshell. This shipped once
    ///   without the parentheses and closed the session after running `whoami`.
    /// - **The body never touches the terminal's input buffer.** Pasting a multi-line
    ///   script into a pty makes the shell execute it line by line as the bytes
    ///   arrive, which mangles quotes, heredocs and `if` blocks, and makes a partial
    ///   run impossible to abort.
    /// - **It is base64, not quoted.** A script can contain any byte; wrapping it in
    ///   single quotes breaks on the first `'`.
    /// - **`mktemp` and a `trap`.** The file goes away on success, on failure, and on
    ///   Ctrl-C — a failed run must not leave an executable copy of the user's script
    ///   on a shared server.
    public static func command(for snippet: Snippet) -> String {
        command(for: snippet, values: [:])
    }

    /// The same command, with parameter values bound.
    ///
    /// Values are supplied by the user, which makes this the one place in the app
    /// where input becomes shell code. They are therefore **never** interpolated into
    /// the command text: each one is base64-encoded and decoded into an environment
    /// assignment by `sh` itself. A value containing `;`, backticks or a quote is then
    /// a variable holding those characters, not a command — and the same holds for a
    /// password with a space or a newline in it.
    ///
    /// The assignments are a command prefix in front of `sh`, so the script sees them
    /// as environment, which is what `$NAME` in a shell script reads.
    public static func command(for snippet: Snippet, values: [String: String]) -> String {
        let encoded = Data(snippet.body.utf8).base64EncodedString()
        let assignments = environmentAssignments(for: snippet, values: values)

        var parts = [
            "( f=$(mktemp /tmp/kremote-snippet-XXXXXX.sh)",
            "trap 'rm -f \"$f\"' EXIT",
            "printf '%s' '\(encoded)' | \(decoder) > \"$f\"",
        ]
        // **The assignments must be the prefix of the `sh` invocation, not a separate
        // statement.** `A=x; sh script` defines a *shell* variable, which is not
        // exported and is invisible to the child; `A=x sh script` puts it in the
        // child's environment, which is what `$A` inside the script reads. Joined with
        // `;` this silently handed every script empty values.
        let invocation = assignments.isEmpty ? "sh \"$f\"" : "\(assignments) sh \"$f\""
        parts.append(invocation)
        parts.append("exit $?")
        parts.append(")")
        return parts.joined(separator: "; ")
    }

    /// `A=$(printf %s B64 | base64 -d) B=… sh` — the prefix that binds values.
    ///
    /// Built as a command-prefix assignment list rather than export statements, so the
    /// variables exist only for the script and not for the interactive shell
    /// afterwards: leaving a password variable defined in the user's session would
    /// leak it to every later command.
    ///
    /// A name that is not a valid shell identifier is skipped — such a variable cannot
    /// be exported at all, and inventing one would silently hand the script nothing.
    static func environmentAssignments(for snippet: Snippet, values: [String: String]) -> String {
        let assignments = snippet.parameters.compactMap { parameter -> String? in
            guard parameter.isValidName else { return nil }
            let value = parameter.value(from: values)
            let encoded = Data(value.utf8).base64EncodedString()
            // A subshell keeps the base64 text out of the scrollback too.
            return "\(parameter.name)=$(printf %s '\(encoded)' | \(decoder))"
        }
        return assignments.joined(separator: " ")
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
