//
//  WorkspaceRailMetrics.swift
//  TablePro
//

import AppKit

internal enum WorkspaceRailMetrics {
    internal struct Layout: Equatable {
        internal let minimumWidth: CGFloat
        internal let iconSize: CGFloat
        internal let fontSize: CGFloat
        /// Above the glyph and below the label alike, inside the selection fill. A source list draws
        /// that fill over the whole row, `intercellSpacing` included, so this padding is the only
        /// space that separates one tile from the next.
        internal let padding: CGFloat
    }

    /// One constant at every size, so the glyph and its own label read as one group: the space
    /// between neighbouring tiles is twice the padding, several times this.
    internal static let iconLabelGap: CGFloat = 3

    /// An icon above a label, the shape Finder's icon view and Reminders' smart lists use,
    /// rather than a source-list row. The minimum width is set by the label: the source-list style
    /// spends 32pt on insets, so the rail has to be wide enough that what is left still
    /// holds a database name at a legible size. `smallSystemFontSize` is the smallest system
    /// size and stays above the 10pt macOS minimum. The row height is measured from the
    /// label rather than declared here, see `WorkspaceRailCellView.rowHeight(for:)`.
    internal static let small = Layout(minimumWidth: 80, iconSize: 20, fontSize: 10, padding: 5)
    internal static let medium = Layout(
        minimumWidth: 90, iconSize: 24, fontSize: NSFont.smallSystemFontSize, padding: 6
    )
    internal static let large = Layout(minimumWidth: 100, iconSize: 28, fontSize: 12, padding: 7)

    /// Room for about 34 characters on each label line, while the object browser keeps its own range.
    internal static let maximumWidth: CGFloat = 240

    /// Mirrors System Settings > Appearance > Sidebar icon size, which AppKit exposes
    /// through `NSTableView.effectiveRowSizeStyle`.
    internal static func layout(for rowSizeStyle: NSTableView.RowSizeStyle) -> Layout {
        switch rowSizeStyle {
        case .small:
            return small
        case .large:
            return large
        case .medium:
            return medium
        default:
            return medium
        }
    }
}
