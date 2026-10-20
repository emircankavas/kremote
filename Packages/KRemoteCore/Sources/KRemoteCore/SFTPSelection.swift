import Foundation

/// How a click changes the selection, in Finder's three flavours.
public enum SFTPSelectionMode: Sendable, Equatable {
    /// A plain click: the selection becomes exactly this row.
    case replace
    /// ⌘-click: this row joins or leaves the selection, everything else stays.
    case toggle
    /// ⇧-click: everything from the anchor to this row, inclusive.
    case extend
}

/// The selection rules of the SFTP browser, as pure functions.
///
/// They live here rather than inside a SwiftUI gesture so the three cases the card
/// asks for — single, ⌘, ⇧ — are testable without a window, and so the list view
/// and the icon view cannot drift apart in how a modified click behaves.
public enum SFTPSelection {

    /// The new selection after clicking `path`.
    ///
    /// `anchor` is where a ⇧-range is measured from. It is updated exactly when
    /// Finder updates it: on a plain click and on a ⌘-click, and *not* on a
    /// ⇧-click, so dragging a range up and down keeps growing from the same origin.
    ///
    /// An extend with no anchor, or with a row that is no longer listed, degrades
    /// to a plain click rather than selecting something arbitrary.
    public static func apply(
        _ mode: SFTPSelectionMode,
        to selection: Set<String>,
        anchor: inout String?,
        path: String,
        order: [String]
    ) -> Set<String> {
        switch mode {
        case .replace:
            anchor = path
            return [path]

        case .toggle:
            var updated = selection
            if updated.contains(path) {
                updated.remove(path)
            } else {
                updated.insert(path)
            }
            anchor = path
            return updated

        case .extend:
            guard let anchor,
                  let start = order.firstIndex(of: anchor),
                  let end = order.firstIndex(of: path) else {
                // No usable anchor: behave like a plain click instead of guessing.
                return apply(.replace, to: selection, anchor: &anchor, path: path, order: order)
            }
            let range = start <= end ? start...end : end...start
            return Set(order[range])
        }
    }

    /// ⌘A: everything currently listed, honouring the hidden-files filter the
    /// caller already applied to `order`.
    public static func all(_ order: [String]) -> Set<String> {
        Set(order)
    }

    /// The selection after a delete or a refresh, with rows that no longer exist
    /// dropped. A selection must never outlive its rows: "Get Info" on a deleted
    /// file would otherwise act on something that is no longer listed.
    public static func pruned(_ selection: Set<String>, to order: [String]) -> Set<String> {
        selection.intersection(Set(order))
    }

    /// The one row an operation like Rename or Show Info should act on, or nil when
    /// the selection is empty or has more than one member.
    public static func single(_ selection: Set<String>, order: [String]) -> String? {
        guard selection.count == 1 else { return nil }
        return order.first { selection.contains($0) }
    }
}
