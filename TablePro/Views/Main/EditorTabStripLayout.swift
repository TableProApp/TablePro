//
//  EditorTabStripLayout.swift
//  TablePro
//

import CoreGraphics
import Foundation

/// The geometry and visibility rules of the editor tab strip, kept apart from the view so they
/// can be tested. Both rules were read off the system tab bar rather than designed.
internal enum EditorTabStripLayout {
    internal static let trackHeight: CGFloat = 28
    internal static let tabHeight: CGFloat = 24
    internal static let trackPadding: CGFloat = 2
    internal static let stripInset: CGFloat = 8
    internal static let trackSpacing: CGFloat = 4
    internal static let newTabButtonSize: CGFloat = 28
    internal static let minimumTabWidth: CGFloat = 120
    internal static let separatorHeight: CGFloat = 18
    internal static let accessoryWidth: CGFloat = 16
    internal static let accessoryInset: CGFloat = 5
    internal static let fontSize: CGFloat = 11

    internal static var totalHeight: CGFloat { trackHeight + stripInset * 2 }

    /// Tabs share the track equally, and stop shrinking at a width that still fits a name so a
    /// long list scrolls instead of collapsing into slivers. The system staggers widths slightly
    /// by an undocumented rule; an equal share is within a couple of points of it.
    internal static func tabWidth(forTrack width: CGFloat, count: Int) -> CGFloat {
        let usable = width - trackPadding * 2
        let divisor = CGFloat(max(count, 1))
        return max(usable / divisor, minimumTabWidth)
    }

    /// A separator is drawn at the leading edge of a tab only when both it and its leading
    /// neighbour are plain and untouched. A line against the raised capsule reads as a seam in
    /// it, and one against a hovered tab fights that tab's fill. Two tabs therefore never show
    /// one, because one of them is always selected.
    internal static func showsSeparator(
        before index: Int,
        tabIds: [UUID],
        selectedId: UUID?,
        hoveredId: UUID?,
        isReordering: Bool = false
    ) -> Bool {
        guard !isReordering, index > 0 else { return false }
        guard tabIds.indices.contains(index), tabIds.indices.contains(index - 1) else { return false }
        let leading = tabIds[index - 1]
        let trailing = tabIds[index]
        guard leading != selectedId, trailing != selectedId else { return false }
        return leading != hoveredId && trailing != hoveredId
    }
}
