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
    /// The width every tab has in an even run, and the width of a tab that asked for none in a run where
    /// some did (`EditorTabStripLayout.tabWidths(forTrack:preferred:)`).
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

    /// Where one tab ends and the next begins along the axis the reorder resolves on, from the leading
    /// edge of the first to the trailing edge of the last. One row as it is drawn, whatever its widths;
    /// a wrapped run, whose tabs are always even, as if it had never wrapped.
    internal var linearBoundaries: [CGFloat] {
        guard !placements.isEmpty else { return [] }
        guard rowCount == 1 else {
            return (0 ... placements.count).map { CGFloat($0) * tabWidth }
        }
        let frames = placements.sorted { $0.index < $1.index }.map(\.frame)
        return [frames[0].minX] + frames.map(\.maxX)
    }
}

/// The pure geometry of the run, kept apart from both the AppKit view and the SwiftUI one.
internal enum EditorTabRunLayoutBuilder {
    /// Lays the run out inside a track of `width`.
    ///
    /// `scroll` keeps one row and lets the content run past the viewport. `rows` fits as many tabs
    /// per row as `minimumTabWidth` allows and wraps, so the content never runs wider than the
    /// track and no tab is ever off screen.
    ///
    /// `preferredWidths`, in run order, are the widths located tabs ask for. Only a scrolling run
    /// honours them: a wrapped run fits its rows by counting even tabs, and an uneven row would leave
    /// its gaps and its reorder projection disagreeing with what is drawn.
    internal static func run(
        forTrack width: CGFloat,
        count: Int,
        overflow: EditorTabStripOverflow,
        preferredWidths: [CGFloat?] = []
    ) -> EditorTabRunLayout {
        guard count > 0, width > 0 else { return .empty }

        if overflow == .scroll, preferredWidths.count == count, preferredWidths.contains(where: { $0 != nil }) {
            let widths = EditorTabStripLayout.tabWidths(forTrack: width, preferred: preferredWidths)
            let share = EditorTabStripLayout.tabWidth(forTrack: width, count: count)
            if widths != Array(repeating: share, count: count) {
                let flexible = preferredWidths.indices.first { preferredWidths[$0] == nil }.map { widths[$0] }
                return unevenRun(widths: widths, flexibleWidth: flexible ?? share)
            }
        }

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

    /// One scrolling row of tabs laid edge to edge at their own widths.
    private static func unevenRun(widths: [CGFloat], flexibleWidth: CGFloat) -> EditorTabRunLayout {
        var leading: CGFloat = 0
        let placements = widths.enumerated().map { index, width -> EditorTabPlacement in
            defer { leading += width }
            return EditorTabPlacement(
                index: index,
                row: 0,
                frame: CGRect(x: leading, y: 0, width: width, height: EditorTabStripLayout.tabHeight)
            )
        }
        return EditorTabRunLayout(
            placements: placements,
            tabWidth: flexibleWidth,
            tabsPerRow: widths.count,
            rowCount: 1,
            contentSize: CGSize(
                width: widths.reduce(0, +),
                height: EditorTabStripLayout.rowStride - EditorTabStripLayout.rowSpacing
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
