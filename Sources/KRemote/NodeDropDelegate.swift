import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KRemoteCore

/// The drag currently in flight, captured at drag start.
///
/// `performDrop` has to answer AppKit synchronously while a pasteboard item loads
/// asynchronously, and blocking the main thread on that load deadlocks. For a drag
/// that starts and ends inside this app the ids are already known, so they are
/// recorded when the drag begins and read when it is dropped. The pasteboard still
/// carries the same payload as a private UTI, which is what stops a drop from
/// accepting text dragged in from another application.
@MainActor
enum NodeDrag {
    private(set) static var ids: [ConnectionNode.ID] = []

    static func begin(_ ids: [ConnectionNode.ID]) {
        self.ids = ids
    }

    static func finish() {
        ids = []
    }
}

/// Accepts a connection-tree drag on one row.
///
/// `DropDelegate` rather than `.dropDestination(for:)` because only the delegate
/// is told about `dropEntered`/`dropExited`, which is what lets a folder row show
/// that it will take the drop and auto-expand the way Finder's tree does. It also
/// reports acceptance honestly: returning `true` from a `dropDestination` handler
/// while nothing moved is what made a failed move look like a working one.
struct NodeDropDelegate: DropDelegate {
    let target: ConnectionNode
    /// Where the drop would put the node (a folder's id, or the target's parent).
    let destination: ConnectionNode.ID?
    let model: AppModel
    let drop: ([ConnectionNode.ID], ConnectionNode.ID?) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.kremoteNode])
    }

    func dropEntered(info: DropInfo) {
        guard !NodeDrag.ids.isEmpty else { return }
        model.dropHighlightID = target.id
    }

    func dropExited(info: DropInfo) {
        if model.dropHighlightID == target.id { model.dropHighlightID = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        model.dropHighlightID = nil
        let ids = NodeDrag.ids
        guard info.hasItemsConforming(to: [.kremoteNode]), !ids.isEmpty else { return false }
        defer { NodeDrag.finish() }
        return drop(ids, destination)
    }
}

/// Accepts a connection-tree drag on the empty part of the sidebar list, which
/// means "move to the top level".
struct RootDropDelegate: DropDelegate {
    let model: AppModel
    let drop: ([ConnectionNode.ID], ConnectionNode.ID?) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.kremoteNode])
    }

    func dropEntered(info: DropInfo) {
        guard !NodeDrag.ids.isEmpty else { return }
        model.isRootDropTarget = true
    }

    func dropExited(info: DropInfo) {
        model.isRootDropTarget = false
    }

    func performDrop(info: DropInfo) -> Bool {
        model.isRootDropTarget = false
        let ids = NodeDrag.ids
        guard info.hasItemsConforming(to: [.kremoteNode]), !ids.isEmpty else { return false }
        defer { NodeDrag.finish() }
        return drop(ids, nil)
    }
}
