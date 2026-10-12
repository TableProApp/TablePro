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
/// rail settles onto instead: zero, and every offset that puts a tile's top edge at the top of the
/// viewport.
///
/// The tile edges are not multiples of the row height. A source list pads its rows with 10pt above
/// the first and below the last, so snapping to multiples left the bottom of the previous tile
/// showing at the top of the strip, a band of accent fill when that tile was selected, and cut the
/// last tile short. `firstRowTop` is that padding, read from the table rather than assumed.
///
/// The document's own end is the case that forces `bottomInset`. A viewport is almost never a whole
/// number of tiles, so the last tile can be reached only from an offset that is not a tile edge;
/// without the inset the rail either stops short of its final entry or slices the tile at the top
/// to reach it. The inset is the empty strip that makes that final offset land on an edge like every
/// other one.
internal struct WorkspaceRailScrollGeometry {
    internal let rowCount: Int
    internal let rowHeight: CGFloat
    internal let firstRowTop: CGFloat
    internal let viewportHeight: CGFloat

    private var isInert: Bool {
        rowHeight <= 0 || rowCount <= 0 || viewportHeight <= 0
    }

    internal func top(ofRow row: Int) -> CGFloat {
        firstRowTop + CGFloat(row) * rowHeight
    }

    /// The furthest the rail may rest while still keeping the last entry whole and a tile edge at
    /// the top of the viewport.
    ///
    /// Measured against the last entry's own bottom, not the document's. The padding under the
    /// final entry is not part of it, so a viewport that ends inside that padding already holds every
    /// entry and needs no scrolling at all.
    internal var maximumRestingOrigin: CGFloat {
        guard !isInert else { return 0 }
        let lastRowBottom = top(ofRow: rowCount)
        guard lastRowBottom > viewportHeight else { return 0 }
        return restingOrigin(atOrAfter: lastRowBottom - viewportHeight)
    }

    /// The empty strip below the last tile that brings `maximumRestingOrigin` within reach.
    ///
    /// `documentHeight` is asked for rather than derived, because `NSTableView` sizes its document
    /// to fill a viewport the rows do not, and pads it past the rows when they overflow.
    internal func bottomInset(documentHeight: CGFloat) -> CGFloat {
        guard !isInert else { return 0 }
        return max(0, maximumRestingOrigin + viewportHeight - documentHeight)
    }

    /// The edge a settled scroll lands on, without cutting an entry the highlight was already
    /// showing whole.
    ///
    /// `NSTableView` reveals the row the arrow keys reach by scrolling the least it can, which stops
    /// between edges; rounding that to the nearest one would cut the entry the keyboard just moved
    /// to. Only an entry that was whole before the snap is protected, so scrolling away from the
    /// highlighted entry on purpose still settles wherever the scroll ended.
    internal func settledOrigin(proposed: CGFloat, selectedRow: Int?) -> CGFloat {
        let maximum = maximumRestingOrigin
        guard !isInert, maximum > 0 else { return 0 }
        let snapped = min(max(0, nearestRestingOrigin(to: proposed)), maximum)
        guard let selectedRow, selectedRow >= 0, selectedRow < rowCount else { return snapped }

        let top = top(ofRow: selectedRow)
        let bottom = top + rowHeight
        func showsSelectionWhole(_ origin: CGFloat) -> Bool {
            top >= origin - 0.5 && bottom <= origin + viewportHeight + 0.5
        }
        guard showsSelectionWhole(proposed), !showsSelectionWhole(snapped) else { return snapped }

        let nearest = restingOrigin(atOrAfter: bottom - viewportHeight)
        let furthest = restingOrigin(atOrBefore: top)
        return min(max(min(max(snapped, nearest), furthest), 0), maximum)
    }

    /// The offset that brings `row` fully into view, or nil while it already is.
    ///
    /// Nil is the answer that lets every caller ask unconditionally. The rail's entries are the same
    /// list in every window, so a change in one window reloads the rail in all of them; a reveal
    /// that moved a rail whose entry was already on screen would drag another window's strip away
    /// from wherever its owner had scrolled it.
    internal func revealOrigin(row: Int, currentOrigin: CGFloat) -> CGFloat? {
        guard !isInert, row >= 0, row < rowCount else { return nil }

        let top = top(ofRow: row)
        let bottom = top + rowHeight
        guard top < currentOrigin || bottom > currentOrigin + viewportHeight else { return nil }

        /// The first entry goes back to the very top, padding included, which is where the strip
        /// starts out.
        let target = top < currentOrigin
            ? (row == 0 ? 0 : top)
            : restingOrigin(atOrAfter: bottom - viewportHeight)
        let clamped = min(max(0, target), maximumRestingOrigin)
        guard abs(clamped - currentOrigin) > 0.5 else { return nil }
        return clamped
    }

    private func restingOrigin(atOrAfter offset: CGFloat) -> CGFloat {
        guard offset > 0 else { return 0 }
        let row = max(0, ((offset - firstRowTop) / rowHeight).rounded(.up))
        return firstRowTop + row * rowHeight
    }

    private func restingOrigin(atOrBefore offset: CGFloat) -> CGFloat {
        guard offset >= firstRowTop else { return 0 }
        let row = ((offset - firstRowTop) / rowHeight).rounded(.down)
        return firstRowTop + row * rowHeight
    }

    private func nearestRestingOrigin(to offset: CGFloat) -> CGFloat {
        let before = restingOrigin(atOrBefore: offset)
        let after = restingOrigin(atOrAfter: offset)
        return after - offset <= offset - before ? after : before
    }
}
