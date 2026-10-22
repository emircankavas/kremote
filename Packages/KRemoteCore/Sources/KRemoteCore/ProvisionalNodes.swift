import Foundation

/// Tracks nodes that exist only because an editor is open on them.
///
/// "New Connection" and "Add as a server" both need a real node for the editor to edit,
/// and a node in the tree is a saved node. Without this, dismissing the editor leaves an
/// empty row behind — every cancelled "New Connection" accumulates in the sidebar, which
/// is exactly what was reported.
///
/// The rule is small but easy to get subtly wrong (a node saved after being provisional
/// must not be deleted by a later cancel, and a cancel must not delete a node the user
/// already had), so it lives here where it can be tested rather than inline in the model.
public struct ProvisionalNodes: Equatable, Sendable {
    private var ids: Set<UUID> = []

    public init() {}

    /// Records a node that was just created for an editor.
    public mutating func begin(_ id: UUID) {
        ids.insert(id)
    }

    /// Records that the node is now saved: it is a real part of the tree from here on.
    public mutating func commit(_ id: UUID) {
        ids.remove(id)
    }

    /// Whether the node is still waiting to be saved.
    public func isProvisional(_ id: UUID) -> Bool {
        ids.contains(id)
    }

    public var count: Int { ids.count }

    /// Ends an editing session and reports whether the node must be removed.
    ///
    /// Returns true only for a node that was created here and never saved — the caller
    /// deletes exactly those. Editing an existing connection never returns true, because
    /// that node predates the editor and the user only declined a change to it.
    ///
    /// Idempotent: the Cancel button and the sheet's dismiss handler both call it, and the
    /// second call does nothing.
    @discardableResult
    public mutating func cancel(_ id: UUID) -> Bool {
        ids.remove(id) != nil
    }
}
