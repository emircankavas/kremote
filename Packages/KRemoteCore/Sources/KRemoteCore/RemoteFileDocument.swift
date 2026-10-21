import Foundation

/// A remote file opened for editing: its text, and the facts needed to save it back
/// without clobbering someone else's change.
///
/// The conflict rule is the point of this type. A text editor that just writes the
/// buffer is fine until two people open the same config file — then the second save
/// silently destroys the first. So the size and modification time from the moment the
/// file was read travel with it, and `save` refuses when they no longer match.
public struct RemoteFileDocument: Equatable, Sendable {
    /// Absolute path on the server.
    public let path: String
    /// The text as loaded, decoded.
    public var text: String
    /// What was on disk when it was read.
    public let originalText: String
    /// Size and mtime at load, for conflict detection.
    public let originalSize: UInt64?
    public let originalModified: Date?
    /// Binary files are refused rather than mangled: a text editor that "saves" a
    /// truncated ELF has destroyed it.
    public let isBinary: Bool
    /// Set when the bytes were not valid UTF-8 and had to be decoded lossily.
    public let hadDecodingLoss: Bool

    public init(
        path: String,
        text: String,
        originalText: String,
        originalSize: UInt64?,
        originalModified: Date?,
        isBinary: Bool,
        hadDecodingLoss: Bool
    ) {
        self.path = path
        self.text = text
        self.originalText = originalText
        self.originalSize = originalSize
        self.originalModified = originalModified
        self.isBinary = isBinary
        self.hadDecodingLoss = hadDecodingLoss
    }

    /// True when the buffer differs from what was loaded.
    public var isDirty: Bool { text != originalText }

    /// The file's name, for the window title.
    public var displayName: String {
        (path as NSString).lastPathComponent
    }

    /// Whether this looks like something a text editor should open at all.
    ///
    /// A NUL byte in the first few kilobytes is the standard heuristic and the one
    /// `git`, `grep` and `file` all use. It is not perfect — UTF-16 text has NULs —
    /// but refusing a UTF-16 file is recoverable, corrupting a binary is not.
    public static func looksBinary(_ data: Data) -> Bool {
        data.prefix(8000).contains(0)
    }

    /// Builds a document from downloaded bytes.
    public static func make(
        path: String,
        data: Data,
        size: UInt64?,
        modified: Date?
    ) -> RemoteFileDocument {
        let binary = looksBinary(data)
        // A UTF-8 decode that fails means the bytes are not text this editor can
        // round-trip; the flag rides along so the UI can say so before a save destroys
        // the original encoding.
        let decoded = String(data: data, encoding: .utf8)
        let text = decoded ?? String(decoding: data, as: UTF8.self)
        return RemoteFileDocument(
            path: path,
            text: text,
            originalText: text,
            originalSize: size,
            originalModified: modified,
            isBinary: binary,
            hadDecodingLoss: decoded == nil && !binary
        )
    }

    /// Whether saving now would overwrite a change made since it was opened.
    ///
    /// Compares mtime first because it is the cheap signal, then size. Both can miss a
    /// same-second edit of equal length — a full checksum would need the file again on
    /// every save, and the session already re-reads before writing, so the remaining
    /// window is a save inside one second of another save of the same byte count.
    public func conflictsWith(currentSize: UInt64?, currentModified: Date?) -> Bool {
        if let originalModified, let currentModified, originalModified != currentModified {
            return true
        }
        if let originalSize, let currentSize, originalSize != currentSize {
            return true
        }
        return false
    }
}

/// The embedded editor's file access, kept behind a protocol so the conflict and
/// dirty logic is testable without a server.
public protocol RemoteFileAccess: Sendable {
    func readFile(_ path: String) async throws -> Data
    func writeFile(_ path: String, data: Data) async throws
    func fileInfo(_ path: String) async throws -> (size: UInt64, modified: Date?)?
}
