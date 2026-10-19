import Foundation

/// The rwx bits of one access class (owner, group, other), as the permissions
/// sheet draws them.
public struct PermissionClass: Sendable, Equatable, Hashable {
    public var read: Bool
    public var write: Bool
    public var execute: Bool

    public init(read: Bool = false, write: Bool = false, execute: Bool = false) {
        self.read = read
        self.write = write
        self.execute = execute
    }

    /// The three bits this class contributes (`rwx` → 0o7).
    public var bits: UInt16 {
        (read ? 0o4 : 0) | (write ? 0o2 : 0) | (execute ? 0o1 : 0)
    }

    public init(bits: UInt16) {
        self.init(
            read: bits & 0o4 != 0,
            write: bits & 0o2 != 0,
            execute: bits & 0o1 != 0
        )
    }

    /// `rwx`, `r-x`, `---` — the way `ls -l` prints one class.
    public var symbolic: String {
        [read ? "r" : "-", write ? "w" : "-", execute ? "x" : "-"].joined()
    }
}

/// A file mode as the permissions sheet edits it: three classes plus the
/// setuid/setgid/sticky bits, and the octal field kept in sync with them.
///
/// The parsing rules are here, in the core, rather than in the view, because
/// they are the only part of the sheet that can be wrong in a way that damages a
/// file: `chmod 600` typed as `chmod 0600` and `chmod 000` must both round-trip,
/// and a rejected keystroke must not silently become a different mode.
public struct PermissionSet: Sendable, Equatable, Hashable {
    public var owner: PermissionClass
    public var group: PermissionClass
    public var other: PermissionClass
    public var setuid = false
    public var setgid = false
    public var sticky = false

    public init(
        owner: PermissionClass = .init(),
        group: PermissionClass = .init(),
        other: PermissionClass = .init(),
        setuid: Bool = false,
        setgid: Bool = false,
        sticky: Bool = false
    ) {
        self.owner = owner
        self.group = group
        self.other = other
        self.setuid = setuid
        self.setgid = setgid
        self.sticky = sticky
    }

    /// From the mode bits only (`st_mode & 0o7777`).
    public init(modeBits: UInt16) {
        self.init(
            owner: PermissionClass(bits: (modeBits >> 6) & 0o7),
            group: PermissionClass(bits: (modeBits >> 3) & 0o7),
            other: PermissionClass(bits: modeBits & 0o7),
            setuid: modeBits & 0o4000 != 0,
            setgid: modeBits & 0o2000 != 0,
            sticky: modeBits & 0o1000 != 0
        )
    }

    /// The mode bits, ready for SETSTAT.
    public var modeBits: UInt16 {
        (setuid ? 0o4000 : 0) | (setgid ? 0o2000 : 0) | (sticky ? 0o1000 : 0)
            | (owner.bits << 6) | (group.bits << 3) | other.bits
    }

    /// `755` — the form the numeric field shows. Never zero-padded, so typing is
    /// not disturbed and a user's `644` stays `644`.
    public var octal: String {
        String(modeBits & 0o7777, radix: 8)
    }

    /// `-rwxr-xr-x`-style text for the sheet's preview line.
    public var symbolic: String {
        var result = ""
        result += owner.symbolic
        result += group.symbolic
        result += other.symbolic
        return result
    }

    /// Parses what a user types into the numeric field.
    ///
    /// Accepts 3 or 4 octal digits, with or without a leading `0`, and ignores
    /// surrounding whitespace. Returns nil for anything else so the field can
    /// refuse the keystroke instead of applying a mode nobody asked for — `8` and
    /// `abc` are not modes, and neither is a 5-digit number.
    public static func parse(octal text: String) -> PermissionSet? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("0o") { trimmed.removeFirst(2) }
        guard !trimmed.isEmpty, trimmed.count <= 4 else { return nil }
        guard trimmed.allSatisfy({ $0 >= "0" && $0 <= "7" }) else { return nil }
        guard let value = UInt16(trimmed, radix: 8) else { return nil }
        return PermissionSet(modeBits: value)
    }

    /// Whether the mode carries any right at all — used to warn before the sheet
    /// makes a file unreadable to everyone, which is legal and usually a mistake.
    public var isDeniedToEveryone: Bool {
        modeBits & 0o7777 == 0
    }
}
