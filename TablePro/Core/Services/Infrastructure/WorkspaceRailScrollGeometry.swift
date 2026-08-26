//
//  WorkspaceRailScrollGeometry.swift
//  TablePro
//

import AppKit

/// Where the rail is allowed to come to rest.
///
/// Every entry is a tile whose meaning is its glyph, laid out across the top of the row, so a
/// viewport edge that falls inside a tile does not read as a partly scrolled row the way a line of
/// text does: it deletes the glyph and leaves the label behind with nothing above it. The rail
/// autohides its scroller, so at rest there is no affordance saying the strip scrolls at all, and
/// that orphaned label reads as a drawing bug. It was reported as one (#2452).
///
/// `NSClipView.constrainBoundsRect` allows any offset between zero and the document's end, so a
/// mid-tile offset is a legal resting position that nothing corrects. These are the offsets the
/// rail settles onto instead, all of them multiples of the row pitch.
///
/// The document's own end is the case that forces `bottomInset`. A viewport is almost never a whole
/// number of tiles, so the last tile can be reached only from an offset that is not a multiple of
/// the pitch; without the inset the rail either stops short of its final entry or slices the tile at
/// the top to reach it. The inset is the empty strip that makes that final offset land on a boundary
/// like every other one.
internal enum WorkspaceRailScrollGeometry {
    /// The furthest the rail may rest while still keeping the last entry whole and a tile edge at
    /// the top of the viewport.
    ///
    /// Measured against the last entry's own bottom rather than by counting whole pitches. The
    /// spacing under the final entry is not part of it, so a viewport that ends between the last
    /// entry and the next boundary already holds every entry: counting pitches called that a scroll
    /// of one whole row and let the first entry be hidden under a strip that fits.
    internal static func maximumRestingOrigin(
        rowCount: Int,
        rowPitch: CGFloat,
        rowHeight: CGFloat,
        viewportHeight: CGFloat
    ) -> CGFloat {
        guard rowPitch > 0, rowCount > 0, viewportHeight > 0 else { return 0 }
        let lastRowBottom = CGFloat(rowCount - 1) * rowPitch + rowHeight
        guard lastRowBottom > viewportHeight else { return 0 }
        return ((lastRowBottom - viewportHeight) / rowPitch).rounded(.up) * rowPitch
    }

    /// The empty strip below the last tile that brings `maximumRestingOrigin` within reach.
    ///
    /// `documentHeight` is asked for rather than derived, because `NSTableView` sizes its document
    /// to fill a viewport the rows do not, and pads it past the rows when they overflow.
    internal static func bottomInset(
        rowCount: Int,
        rowPitch: CGFloat,
        rowHeight: CGFloat,
        documentHeight: CGFloat,
        viewportHeight: CGFloat
    ) -> CGFloat {
        guard rowPitch > 0, rowCount > 0, viewportHeight > 0 else { return 0 }
        let maximum = maximumRestingOrigin(
            rowCount: rowCount, rowPitch: rowPitch, rowHeight: rowHeight, viewportHeight: viewportHeight
        )
        return max(0, maximum + viewportHeight - documentHeight)
    }

    /// The boundary a settled scroll lands on.
    internal static func settledOrigin(
        proposed: CGFloat,
        rowPitch: CGFloat,
        maximumOrigin: CGFloat
    ) -> CGFloat {
        guard rowPitch > 0, maximumOrigin > 0 else { return 0 }
        let snapped = (proposed / rowPitch).rounded() * rowPitch
        return min(max(0, snapped), maximumOrigin)
    }

    /// The boundary a settled scroll lands on, without cutting an entry the highlight was already
    /// showing whole.
    ///
    /// `NSTableView` reveals the row the arrow keys reach by scrolling the least it can, which stops
    /// between boundaries; rounding that to the nearest one would cut the entry the keyboard just
    /// moved to. Only an entry that was whole before the snap is protected, so scrolling away from
    /// the highlighted entry on purpose still settles wherever the scroll ended.
    internal static func settledOrigin(
        proposed: CGFloat,
        selectedRow: Int?,
        rowCount: Int,
        rowPitch: CGFloat,
        rowHeight: CGFloat,
        viewportHeight: CGFloat
    ) -> CGFloat {
        let maximum = maximumRestingOrigin(
            rowCount: rowCount, rowPitch: rowPitch, rowHeight: rowHeight, viewportHeight: viewportHeight
        )
        let snapped = settledOrigin(proposed: proposed, rowPitch: rowPitch, maximumOrigin: maximum)
        guard rowPitch > 0, viewportHeight > 0, rowCount > 0 else { return snapped }
        guard let selectedRow, selectedRow >= 0, selectedRow < rowCount else { return snapped }

        let top = CGFloat(selectedRow) * rowPitch
        let bottom = top + rowHeight
        func showsSelectionWhole(_ origin: CGFloat) -> Bool {
            top >= origin - 0.5 && bottom <= origin + viewportHeight + 0.5
        }
        guard showsSelectionWhole(proposed), !showsSelectionWhole(snapped) else { return snapped }

        let nearest = ((bottom - viewportHeight) / rowPitch).rounded(.up) * rowPitch
        let furthest = (top / rowPitch).rounded(.down) * rowPitch
        return min(max(min(max(snapped, nearest), furthest), 0), maximum)
    }

    /// The offset that brings `row` fully into view, or nil while it already is.
    ///
    /// Nil is the answer that lets every caller ask unconditionally. The rail's entries are the same
    /// list in every window, so a change in one window reloads the rail in all of them; a reveal
    /// that moved a rail whose entry was already on screen would drag another window's strip away
    /// from wherever its owner had scrolled it.
    internal static func revealOrigin(
        row: Int,
        rowCount: Int,
        rowPitch: CGFloat,
        rowHeight: CGFloat,
        viewportHeight: CGFloat,
        currentOrigin: CGFloat
    ) -> CGFloat? {
        guard rowPitch > 0, rowCount > 0, viewportHeight > 0 else { return nil }
        guard row >= 0, row < rowCount else { return nil }

        let top = CGFloat(row) * rowPitch
        let bottom = top + rowHeight
        guard top < currentOrigin || bottom > currentOrigin + viewportHeight else { return nil }

        let maximum = maximumRestingOrigin(
            rowCount: rowCount, rowPitch: rowPitch, rowHeight: rowHeight, viewportHeight: viewportHeight
        )
        let target = top < currentOrigin
            ? top
            : ((bottom - viewportHeight) / rowPitch).rounded(.up) * rowPitch
        let clamped = min(max(0, target), maximum)
        guard abs(clamped - currentOrigin) > 0.5 else { return nil }
        return clamped
    }
}
