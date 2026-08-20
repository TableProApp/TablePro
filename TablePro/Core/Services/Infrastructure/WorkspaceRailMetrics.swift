//
//  WorkspaceRailMetrics.swift
//  TablePro
//

import AppKit

internal enum WorkspaceRailMetrics {
    internal struct Layout: Equatable {
        internal let width: CGFloat
        internal let rowHeight: CGFloat
        internal let iconSize: CGFloat
        internal let fontSize: CGFloat
    }

    /// An icon above a label, the shape Finder's icon view and Reminders' smart lists use,
    /// rather than a source-list row. The width is set by the label: the source-list style
    /// spends 32pt on insets, so the rail has to be wide enough that what is left still
    /// holds a database name at a legible size. `smallSystemFontSize` is the smallest system
    /// size and stays above the 10pt macOS minimum.
    internal static let small = Layout(width: 80, rowHeight: 52, iconSize: 20, fontSize: 10)
    internal static let medium = Layout(
        width: 90, rowHeight: 58, iconSize: 24, fontSize: NSFont.smallSystemFontSize
    )
    internal static let large = Layout(width: 100, rowHeight: 66, iconSize: 28, fontSize: 12)

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
