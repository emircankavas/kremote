import Foundation

/// Sizes the session tab strip the way a browser does: tabs shrink together as
/// more open, down to a floor, and only the tabs that cannot fit at that floor
/// spill into an overflow menu.
///
/// Kept in the core (rather than inline in the view) because the arithmetic is
/// what decides whether "the sixth tab is invisible or in a menu", and that is
/// worth a unit test.
public struct TabStripLayout: Equatable, Sendable {
    /// Below this a tab shows only its icon and close button.
    public static let minWidth: CGFloat = 96
    /// A tab never grows past this, or one session would own the whole strip.
    public static let maxWidth: CGFloat = 240
    public static let gap: CGFloat = 2

    /// Every open tab, in order.
    public var count: Int
    /// The width available for tabs (the strip minus the trailing "+" button).
    public var available: CGFloat

    public init(count: Int, available: CGFloat) {
        self.count = max(0, count)
        self.available = max(0, available)
    }

    /// How many tabs fit at the minimum width.
    public var visibleCapacity: Int {
        guard available > 0 else { return 0 }
        // n tabs need n*min + (n-1)*gap.
        let fits = Int(((available + Self.gap) / (Self.minWidth + Self.gap)).rounded(.down))
        return max(0, fits)
    }

    /// Tabs drawn inline; the rest go in the overflow menu.
    public var visibleCount: Int {
        min(count, visibleCapacity)
    }

    public var overflowCount: Int {
        count - visibleCount
    }

    /// Width of one inline tab: shared evenly, clamped between the floor and the
    /// cap, so two tabs are not stretched to 400 pt each.
    public var tabWidth: CGFloat {
        guard visibleCount > 0 else { return 0 }
        let total = available - CGFloat(visibleCount - 1) * Self.gap
        return min(Self.maxWidth, max(Self.minWidth, total / CGFloat(visibleCount)))
    }

    /// Whether a tab is narrow enough that its title no longer fits usefully.
    public var showsOnlyIcon: Bool { tabWidth < 140 }
}

/// Reordering for the tab strip.
///
/// A pure array move, separate from `AppModel` so the index arithmetic (the part
/// that is easy to get wrong when the drop index sits to the right of the source)
/// is testable.
public enum TabOrdering {
    /// Moves the element at `source` so it sits at `destination`.
    ///
    /// `destination` is interpreted as an index into the array *as it looks after
    /// the element has been removed* — which is what a drop indicator drawn
    /// between two tabs means.
    public static func move<T>(_ items: [T], from source: Int, to destination: Int) -> [T] {
        guard items.indices.contains(source) else { return items }
        let clamped = min(max(destination, 0), items.count - 1)
        guard clamped != source else { return items }
        var copy = items
        let item = copy.remove(at: source)
        copy.insert(item, at: clamped)
        return copy
    }
}
