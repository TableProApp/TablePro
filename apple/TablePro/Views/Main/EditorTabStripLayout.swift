//
//  EditorTabStripLayout.swift
//  TablePro
//

import CoreGraphics
import Foundation
import QuartzCore

// Measured off the system's own window tab bar on macOS 27.
internal enum EditorTabStripLayout {
    internal static let bandHeight: CGFloat = 36
    internal static let trackHeight: CGFloat = 28
    internal static let tabHeight: CGFloat = 24
    internal static let trackPadding: CGFloat = 2
    internal static let stripInset: CGFloat = 8
    internal static let trackSpacing: CGFloat = 4
    internal static let newTabButtonSize: CGFloat = 28
    internal static let minimumTabWidth: CGFloat = 120
    internal static let separatorHeight: CGFloat = 16
    internal static let separatorWidth: CGFloat = 1
    internal static let hairline: CGFloat = 0.5

    internal static let accessoryWidth: CGFloat = 16
    internal static let accessoryInset: CGFloat = 5
    internal static let fontSize: CGFloat = 11
    internal static let pinGlyphSize: CGFloat = 9
    internal static let pinSpacing: CGFloat = 3
    internal static let statusGlyphSize: CGFloat = 10
    internal static let closeGlyphSize: CGFloat = 9
    internal static let newTabGlyphSize: CGFloat = 12

    // Below this a collapsed tab has no room for anything but its edge.
    internal static let minimumContentWidth: CGFloat = 44

    // Keeps the name field and its focus ring inside the tab's capsule.
    internal static let renameFieldInset: CGFloat = 8

    // The HIG's distance for showing a drag image.
    internal static let dragThreshold: CGFloat = 3

    internal static let autoscrollMargin: CGFloat = 24
    internal static let autoscrollStep: CGFloat = 12

    // The system bar settles an opened or closed tab along this curve.
    internal static let motionDuration: TimeInterval = 0.32
    internal static var motionTiming: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.22, 0.9, 0.3, 1)
    }

    internal static func tabWidth(forViewport width: CGFloat, count: Int) -> CGFloat {
        guard count > 0 else { return minimumTabWidth }
        return max(width / CGFloat(count), minimumTabWidth)
    }

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
