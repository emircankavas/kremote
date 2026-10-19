import Foundation

/// What the user chose for a name that already exists.
///
/// The three answers the card requires. `replace` and `keepBoth` happen in the
/// enqueue path, before any byte moves; `skip` drops the item from the batch and
/// is reported in the batch summary rather than silently forgotten.
public enum ConflictResolution: String, Sendable, CaseIterable, Identifiable {
    case replace
    case keepBoth
    case skip

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .replace: return "Replace"
        case .keepBoth: return "Keep Both"
        case .skip: return "Skip"
        }
    }

    public var isActionable: Bool { self != .skip }
}

/// Finder's numbering rule for "Keep Both".
///
/// `report.txt` → `report 2.txt` → `report 3.txt`, and the extension is kept last
/// so an application still recognises the file. A name that already has a
/// trailing number continues from the next free one rather than stacking
/// (`report 2.txt` → `report 3.txt`, not `report 2 2.txt`).
public enum ConflictResolver {

    /// The first free name, given what already exists.
    ///
    /// `existing` is compared case-insensitively because macOS volumes usually
    /// are; the caller passes the names it can see.
    public static func keepBothName(for name: String, existing: Set<String>) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }

        let (base, suffix) = split(name)
        var counter = 2
        // Strip an existing " 2"-style tail so numbering never accumulates.
        var stem = base
        if let match = trailingNumber(base) {
            stem = match.0
            counter = max(2, match.1 + 1)
        }
        while true {
            let candidate = "\(stem) \(counter)\(suffix)"
            if !taken.contains(candidate.lowercased()) { return candidate }
            counter += 1
            // A century of collisions on one name is not a real case; stop rather
            // than spin if the caller handed us a bizarre set.
            if counter > 9999 { return "\(stem) copy\(suffix)" }
        }
    }

    /// Splits `name` into stem and extension, treating a leading dot as part of
    /// the stem so `.bashrc` is not read as extension "bashrc".
    static func split(_ name: String) -> (String, String) {
        let ns = name as NSString
        let ext = ns.pathExtension
        guard !ext.isEmpty, !name.hasPrefix(".") else { return (name, "") }
        return (ns.deletingPathExtension, ".\(ext)")
    }

    /// `("report", 2)` for `report 2`; nil when there is no such tail.
    static func trailingNumber(_ base: String) -> (String, Int)? {
        guard let space = base.lastIndex(of: " ") else { return nil }
        let tail = base[base.index(after: space)...]
        guard !tail.isEmpty, tail.allSatisfy(\.isNumber), let value = Int(tail) else { return nil }
        let stem = String(base[..<space])
        guard !stem.isEmpty else { return nil }
        return (stem, value)
    }
}
