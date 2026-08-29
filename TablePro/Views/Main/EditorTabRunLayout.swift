//
//  EditorTabRunLayout.swift
//  TablePro
//

import CoreGraphics
import Foundation
import SwiftUI

/// What the strip does once the tabs stop fitting.
///
/// `scroll` is the system's answer and stays the default: every tab bar Apple ships, in Finder,
/// Safari and Terminal, keeps one row and scrolls it. `rows` is offered because a tab bar that
/// scrolls hides the tabs a user opened first, which is the complaint #2438 was filed about, and
/// it is opt-in for the same reason.
internal enum EditorTabStripOverflow: String, CaseIterable, Codable, Sendable {
    case scroll
    case rows

    internal var displayName: String {
        switch self {
        case .scroll: return String(localized: "Scroll them")
        case .rows: return String(localized: "Wrap onto more rows")
        }
    }
}

/// Where one tab sits in the run, in the track's content space.
internal struct EditorTabPlacement: Equatable {
    internal let index: Int
    internal let row: Int
    internal let frame: CGRect
}

/// The whole run of tabs: where each one sits, how many rows it took, and how big the content is.
///
/// This is the single source of geometry for the strip. The AppKit view that owns the pointer
/// hit-tests against it, the reorder resolves against it, and SwiftUI draws from it, so a tab the
/// user can see, a tab the pointer can hit and a tab the drag can target are the same rectangle by
/// construction rather than by three views agreeing.
internal struct EditorTabRunLayout: Equatable {
    internal let placements: [EditorTabPlacement]
    internal let tabWidth: CGFloat
    internal let tabsPerRow: Int
    internal let rowCount: Int
    internal let contentSize: CGSize

    internal static let empty = EditorTabRunLayout(
        placements: [],
        tabWidth: 0,
        tabsPerRow: 1,
        rowCount: 1,
        contentSize: .zero
    )

    internal func placement(at index: Int) -> EditorTabPlacement? {
        placements.first { $0.index == index }
    }
}

/// The pure geometry of the run, kept apart from both the AppKit view and the SwiftUI one.
internal enum EditorTabRunLayoutBuilder {
    /// Lays the run out inside a track of `width`.
    ///
    /// `scroll` keeps one row and lets the content run past the viewport. `rows` fits as many tabs
    /// per row as `minimumTabWidth` allows and wraps, so the content never runs wider than the
    /// track and no tab is ever off screen.
    internal static func run(
        forTrack width: CGFloat,
        count: Int,
        overflow: EditorTabStripOverflow
    ) -> EditorTabRunLayout {
        guard count > 0, width > 0 else { return .empty }

        let usable = max(width - EditorTabStripLayout.trackPadding * 2, 0)
        let perRow = tabsPerRow(usable: usable, count: count, overflow: overflow)
        let rows = Int(ceil(Double(count) / Double(max(perRow, 1))))
        let tabWidth = overflow == .scroll
            ? EditorTabStripLayout.tabWidth(forTrack: width, count: count)
            : usable / CGFloat(max(perRow, 1))

        let placements = (0 ..< count).map { index -> EditorTabPlacement in
            let row = index / max(perRow, 1)
            let column = index % max(perRow, 1)
            return EditorTabPlacement(
                index: index,
                row: row,
                frame: CGRect(
                    x: CGFloat(column) * tabWidth,
                    y: CGFloat(row) * EditorTabStripLayout.rowStride,
                    width: tabWidth,
                    height: EditorTabStripLayout.tabHeight
                )
            )
        }

        return EditorTabRunLayout(
            placements: placements,
            tabWidth: tabWidth,
            tabsPerRow: max(perRow, 1),
            rowCount: max(rows, 1),
            contentSize: CGSize(
                width: overflow == .scroll ? tabWidth * CGFloat(count) : usable,
                height: CGFloat(max(rows, 1)) * EditorTabStripLayout.rowStride
                    - EditorTabStripLayout.rowSpacing
            )
        )
    }

    private static func tabsPerRow(usable: CGFloat, count: Int, overflow: EditorTabStripOverflow) -> Int {
        guard overflow == .rows else { return count }
        let fitting = Int(floor(usable / EditorTabStripLayout.minimumTabWidth))
        return max(min(fitting, count), 1)
    }

    /// The tab a point in content space lands on, or nil for the gaps a wrapped last row leaves.
    internal static func index(at point: CGPoint, in run: EditorTabRunLayout) -> Int? {
        run.placements.first { $0.frame.contains(point) }?.index
    }

    /// The close button's target, which the pointer owner needs because the button is drawn by
    /// SwiftUI but no longer clicked through it.
    internal static func closeButtonRect(in frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX + EditorTabStripLayout.accessoryInset,
            y: frame.midY - EditorTabStripLayout.accessoryWidth / 2,
            width: EditorTabStripLayout.accessoryWidth,
            height: EditorTabStripLayout.accessoryWidth
        )
    }

    /// Flattens a point in the run onto the single axis the reorder resolves along.
    ///
    /// One row is already that axis. A wrapped run is not, so a point is projected onto the run it
    /// would have been had it never wrapped: the row it is over contributes a whole row of tabs,
    /// and the offset inside the row contributes the rest. The reorder rule then stays the one
    /// rule, with its midpoint hysteresis, rather than growing a second one for rows.
    internal static func linearLocation(of point: CGPoint, in run: EditorTabRunLayout) -> CGFloat {
        guard run.tabWidth > 0 else { return 0 }
        guard run.rowCount > 1 else { return point.x }
        let row = min(max(Int(floor(point.y / EditorTabStripLayout.rowStride)), 0), run.rowCount - 1)
        let clampedX = min(max(point.x, 0), run.tabWidth * CGFloat(run.tabsPerRow))
        return CGFloat(row * run.tabsPerRow) * run.tabWidth + clampedX
    }
}
