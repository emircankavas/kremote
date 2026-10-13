import Foundation

/// How the detail area is divided into terminal panes.
///
/// 1 pane  → full width
/// 2 panes → side by side (one row, two columns)
/// 3 panes → 2×2 grid with one cell empty (row-major: TL, TR, BL)
/// 4 panes → 2×2 grid
public struct PaneLayout: Codable, Equatable, Sendable {
    public static let maximum = 4
    public static let minimum = 1

    public var count: Int

    public init(count: Int) {
        self.count = Swift.min(Swift.max(count, Self.minimum), Self.maximum)
    }

    public var columns: Int { count == 1 ? 1 : 2 }
    public var rows: Int { count <= 2 ? 1 : 2 }
    public var isSplit: Bool { count > 1 }
}

/// Pure tile-assignment logic, kept in the core so it can be unit-tested apart
/// from the UI. A "tile" is one visible pane; tiles hold sessions (by id), and a
/// tile may be empty (`nil`).
public enum PaneTiling {

    /// Recomputes the tile rows for a given pane count and open sessions.
    ///
    /// - Existing assignments that still point at an open session are kept.
    /// - Assignments for closed sessions are dropped.
    /// - Empty tiles are filled, in order, from sessions that are not yet tiled.
    /// - The result is trimmed (or padded) to `paneCount`.
    public static func reconcile(
        existing: [UUID?],
        sessionIDs: [UUID],
        paneCount: Int
    ) -> [UUID?] {
        let count = min(max(paneCount, PaneLayout.minimum), PaneLayout.maximum)
        let open = Set(sessionIDs)

        var tiles: [UUID?] = (0..<count).map { index in
            guard index < existing.count, let id = existing[index], open.contains(id) else { return nil }
            return id
        }

        // Drop duplicates that a stale state could have produced.
        var seen = Set<UUID>()
        for index in tiles.indices {
            if let id = tiles[index] {
                if seen.contains(id) { tiles[index] = nil } else { seen.insert(id) }
            }
        }

        // Fill empty tiles from the sessions that are not tiled anywhere.
        var untiled = sessionIDs.filter { !seen.contains($0) }
        for index in tiles.indices where tiles[index] == nil {
            guard !untiled.isEmpty else { break }
            let id = untiled.removeFirst()
            tiles[index] = id
            seen.insert(id)
        }
        return tiles
    }

    /// Places `session` into the tiling: the first empty tile, else the focused
    /// tile (replacing whatever was there).
    public static func place(
        session: UUID,
        in tiles: inout [UUID?],
        focusedTile: Int
    ) {
        guard !tiles.isEmpty else { return }
        if let empty = tiles.firstIndex(where: { $0 == nil }) {
            tiles[empty] = session
            return
        }
        let target = min(max(focusedTile, 0), tiles.count - 1)
        tiles[target] = session
    }

    /// The tile index showing `session`, if any.
    public static func tile(of session: UUID, in tiles: [UUID?]) -> Int? {
        tiles.firstIndex { $0 == session }
    }

    /// Session ids in `tiles` that are still in `sessionIDs`, in tile order.
    public static func tiledSessions(in tiles: [UUID?], sessionIDs: [UUID]) -> [UUID] {
        let open = Set(sessionIDs)
        return tiles.compactMap { $0 }.filter { open.contains($0) }
    }
}
