//
//  ColumnWindowResolver.swift
//  TablePro
//

import Foundation

/// Chooses which columns a wide result keeps mounted.
///
/// `NSTableView` virtualises rows but never columns: a prepared row builds one cell view for every
/// column that is not hidden, whatever the horizontal viewport shows. At 500 columns that is
/// ~18,000 live views, and every scroll frame lays out and draws all of them. Hidden columns cost
/// almost nothing, so the fix is to keep only the columns near the viewport unhidden and give the
/// document its full width back through a spacer at each end.
///
/// Pure on purpose: the geometry is the part worth testing, and it needs no table view to decide.
internal enum ColumnWindowResolver {
    /// Columns kept mounted on each side of the viewport, so a small scroll does not re-window.
    internal static let overscan = 10

    /// Columns of headroom that must remain between the viewport and the edge of the mounted range
    /// before the window is left alone.
    ///
    /// Must stay below `overscan`, or the margin can never be satisfied and every scroll re-windows.
    /// Sliding per column put the re-window tile inside the scroll frame and traded a steady cost
    /// for an intermittent stall, so the window holds until this headroom is spent and then jumps
    /// by a whole overscan.
    internal static let slideMargin = 3

    internal struct Window: Equatable {
        let range: Range<Int>
        let leadingWidth: CGFloat
        let trailingWidth: CGFloat

        internal static let empty = Window(range: 0..<0, leadingWidth: 0, trailingWidth: 0)
    }

    /// - Parameter current: the mounted range, so an unchanged decision returns it verbatim and the
    ///   caller can skip the tile entirely.
    internal static func resolve(
        columnWidths: [CGFloat],
        viewportMinX: CGFloat,
        viewportWidth: CGFloat,
        current: Range<Int>?
    ) -> Window {
        guard !columnWidths.isEmpty else { return .empty }
        guard viewportWidth > 0 else {
            return window(for: 0..<min(columnWidths.count, overscan * 2), columnWidths: columnWidths)
        }

        let visible = visibleRange(
            columnWidths: columnWidths,
            viewportMinX: max(0, viewportMinX),
            viewportWidth: viewportWidth
        )
        let desired = padded(visible, count: columnWidths.count)

        if let current, current.lowerBound <= visible.lowerBound, current.upperBound >= visible.upperBound {
            let leadingSlack = visible.lowerBound - current.lowerBound
            let trailingSlack = current.upperBound - visible.upperBound
            let atStart = current.lowerBound == 0
            let atEnd = current.upperBound == columnWidths.count
            if (leadingSlack >= slideMargin || atStart) && (trailingSlack >= slideMargin || atEnd) {
                return window(for: current, columnWidths: columnWidths)
            }
        }

        return window(for: desired, columnWidths: columnWidths)
    }

    /// A window over `index`, for a caller that needs a column's frame before the viewport has
    /// reached it.
    ///
    /// Re-centres rather than stretching the mounted range out to reach the target. Spanning from
    /// the current range to a far column mounts every column in between, which is the whole cost
    /// the window exists to avoid: measured at 848ms and 3,081 cell views for one Find match 90
    /// columns away, and 4.8s at 500 columns. The caller scrolls in the same turn, so the columns
    /// this drops were never drawn again anyway.
    ///
    /// - Returns: `nil` when the range already covers `index` and there is nothing to mount.
    internal static func window(
        containing index: Int,
        columnWidths: [CGFloat],
        current: Range<Int>?
    ) -> Window? {
        guard columnWidths.indices.contains(index) else { return nil }
        if let current, current.contains(index) { return nil }
        return window(for: padded(index..<(index + 1), count: columnWidths.count), columnWidths: columnWidths)
    }

    /// The columns the viewport actually intersects. Always at least one column, so a viewport
    /// narrower than a single column still mounts the one under it.
    private static func visibleRange(
        columnWidths: [CGFloat],
        viewportMinX: CGFloat,
        viewportWidth: CGFloat
    ) -> Range<Int> {
        let viewportMaxX = viewportMinX + viewportWidth
        var offset: CGFloat = 0
        var first: Int?
        var last = columnWidths.count - 1

        for (index, width) in columnWidths.enumerated() {
            let columnMaxX = offset + width
            if first == nil, columnMaxX > viewportMinX {
                first = index
            }
            if offset >= viewportMaxX {
                last = max(index - 1, first ?? 0)
                break
            }
            offset = columnMaxX
        }

        let lower = first ?? max(columnWidths.count - 1, 0)
        return lower..<min(max(last + 1, lower + 1), columnWidths.count)
    }

    private static func padded(_ range: Range<Int>, count: Int) -> Range<Int> {
        let lower = max(0, range.lowerBound - overscan)
        let upper = min(count, range.upperBound + overscan)
        return lower..<upper
    }

    private static func window(for range: Range<Int>, columnWidths: [CGFloat]) -> Window {
        let leading = columnWidths[0..<range.lowerBound].reduce(0, +)
        let trailing = columnWidths[range.upperBound...].reduce(0, +)
        return Window(range: range, leadingWidth: leading, trailingWidth: trailing)
    }
}
