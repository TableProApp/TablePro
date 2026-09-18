//
//  GridDragClamp.swift
//  TablePro
//

import CoreGraphics

/// Which row and column a drag point names, once `NSTableView`'s "outside" sentinel is read
/// correctly.
///
/// `column(at:)` and `row(at:)` both answer -1 for a point outside every column or row, at *either*
/// end. The grid used to clamp that sentinel as though it could only mean "before the first", so a
/// drag past the trailing edge collapsed the selection back to the near edge instead of holding at
/// the far one.
///
/// Measured on a table 429pt wide whose row-number column sits at index 0:
///
///     column(at: x = 5000) = -1      column(at: x = -30) = -1
///     row(at: y = 99999)   = -1      row(at: y = -30)    = -1
///
/// So the point decides, not the sentinel. Pure, and separate from the tracking loop, so the
/// behaviour is testable without a live drag.
enum GridDragClamp {
    /// - Returns: the presented column the point names, or nil when the grid presents none.
    static func column(
        hit: Int,
        pointX: CGFloat,
        firstPresented: Int,
        lastPresented: Int,
        lastPresentedMaxX: CGFloat
    ) -> Int? {
        guard firstPresented >= 0, lastPresented >= firstPresented else { return nil }
        guard hit < 0 else { return min(max(hit, firstPresented), lastPresented) }
        return pointX >= lastPresentedMaxX ? lastPresented : firstPresented
    }

    /// - Returns: the row the point names, or nil when the grid has no rows.
    static func row(hit: Int, pointY: CGFloat, rowCount: Int, lastRowMaxY: CGFloat) -> Int? {
        guard rowCount > 0 else { return nil }
        guard hit < 0 else { return min(hit, rowCount - 1) }
        return pointY >= lastRowMaxY ? rowCount - 1 : 0
    }
}
