import Foundation

/// One value a snippet asks for before it runs.
///
/// Named, not positional: a script reads `$TARGET_HOST`, which explains itself, where
/// `$3` only makes sense to whoever wrote the invocation.
public struct SnippetParameter: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    /// The variable name as the script spells it, without `$`. Uppercase by
    /// convention; validation does not enforce a case so imported snippets keep theirs.
    public var name: String
    /// Pre-filled value. A parameter with no default must be supplied at run time.
    public var defaultValue: String
    /// Shown under the field, e.g. "the host to ping".
    public var note: String
    /// Whether the value appears in the shell as typed (e.g. a password).
    public var isSecret: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        defaultValue: String = "",
        note: String = "",
        isSecret: Bool = false
    ) {
        self.id = id
        self.name = name
        self.defaultValue = defaultValue
        self.note = note
        self.isSecret = isSecret
    }

    /// A name the shell will accept as a variable.
    ///
    /// `[A-Za-z_][A-Za-z0-9_]*` — anything else cannot be exported at all, so the
    /// editor refuses it instead of building a command that silently does nothing.
    public var isValidName: Bool {
        Self.isValidName(name)
    }

    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// Whether the run cannot start without a value.
    public var isRequired: Bool {
        defaultValue.isEmpty
    }

    /// The value to use, falling back to the default.
    public func value(from supplied: [String: String]) -> String {
        supplied[name] ?? defaultValue
    }
}

/// A snippet plus the values chosen for this particular run.
///
/// Values are deliberately *not* stored with the snippet: the answer to "which server"
/// changes every time, and a remembered one is a command aimed at the wrong host
/// waiting to happen. Only the snippet's own defaults persist.
public struct SnippetRun: Equatable, Sendable {
    public let snippet: Snippet
    /// Variable name → value, for this run only.
    public var values: [String: String]

    public init(snippet: Snippet, values: [String: String] = [:]) {
        self.snippet = snippet
        self.values = values
    }

    /// Seeds the form from the snippet's defaults.
    public static func prepared(_ snippet: Snippet) -> SnippetRun {
        var values: [String: String] = [:]
        for parameter in snippet.parameters {
            values[parameter.name] = parameter.defaultValue
        }
        return SnippetRun(snippet: snippet, values: values)
    }

    /// Names that are required and still empty.
    public var missingRequired: [SnippetParameter] {
        snippet.parameters.filter { parameter in
            parameter.isRequired
                && (values[parameter.name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// Whether the Run button may be pressed.
    public var canRun: Bool {
        missingRequired.isEmpty && snippet.parameters.allSatisfy(\.isValidName)
    }

    /// The final command, with values bound for the shell.
    public func command() -> String {
        SnippetLibrary.command(for: snippet, values: values)
    }

    /// What the user is agreeing to, with secrets hidden.
    ///
    /// A confirmation dialog that prints a password in full trains people to click
    /// through it; one that masks it still shows what is about to run.
    public func previewValues() -> [(name: String, value: String)] {
        snippet.parameters.map { parameter in
            let raw = values[parameter.name] ?? parameter.defaultValue
            if parameter.isSecret, !raw.isEmpty {
                return (parameter.name, String(repeating: "•", count: max(4, min(raw.count, 12))))
            }
            return (parameter.name, raw)
        }
    }
}

/// Finds the variables a script refers to, so the editor can offer them.
public enum SnippetParameterScanner {

    /// Variable names the body reads, in first-appearance order, deduplicated.
    ///
    /// Matches `$NAME` and `${NAME}`. Deliberately does *not* try to match `$$`, `$1`,
    /// `$?`, `$@` or `$!`: those are shell-provided, and offering an input for them
    /// would produce a command that sets a variable nothing reads.
    ///
    /// This is a convenience, not a parser: a `$NAME` inside a single-quoted string is
    /// not expanded by the shell and will still be found here. The list is shown for
    /// the user to edit, and wrong suggestions are one click to remove.
    public static func scan(_ body: String) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        let characters = Array(body)
        var index = 0

        while index < characters.count {
            guard characters[index] == "$" else {
                index += 1
                continue
            }
            var cursor = index + 1

            // `${NAME}` form.
            if cursor < characters.count, characters[cursor] == "{" {
                cursor += 1
                var name = ""
                while cursor < characters.count, isNameCharacter(characters[cursor]) {
                    name.append(characters[cursor])
                    cursor += 1
                }
                if !name.isEmpty, isValidStart(name) {
                    append(name, into: &found, seen: &seen)
                }
                index = max(cursor, index + 1)
                continue
            }

            var name = ""
            while cursor < characters.count, isNameCharacter(characters[cursor]) {
                name.append(characters[cursor])
                cursor += 1
            }
            if !name.isEmpty, isValidStart(name) {
                append(name, into: &found, seen: &seen)
                index = cursor
            } else {
                index += 1
            }
        }
        return found
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private static func isValidStart(_ name: String) -> Bool {
        guard let first = name.first else { return false }
        return first.isLetter || first == "_"
    }

    private static func append(_ name: String, into found: inout [String], seen: inout Set<String>) {
        guard !seen.contains(name) else { return }
        seen.insert(name)
        found.append(name)
    }
}
