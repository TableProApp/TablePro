//
//  TextLayoutManager+Invalidation.swift
//  TableProTextEngine
//
//  Created by Khan Winter on 2/24/24.
//

import Foundation

extension TextLayoutManager {
    /// Invalidates layout for the given rect.
    /// - Parameter rect: The rect to invalidate.
    public func invalidateLayoutForRect(_ rect: NSRect) {
        for linePosition in lineStorage.linesStartingAt(rect.minY, until: rect.maxY) {
            linePosition.data.setNeedsLayout()
            invalidateGeometry(in: linePosition.range)
        }

        layoutView?.needsLayout = true
    }

    /// Invalidates layout for the given range of text.
    /// - Parameter range: The range of text to invalidate.
    public func invalidateLayoutForRange(_ range: NSRange) {
        invalidateGeometry(in: range)

        for linePosition in lineStorage.linesInRange(range) {
            linePosition.data.setNeedsLayout()
        }

        // Special case where we've deleted from the very end, `linesInRange` correctly does not return any lines
        // So we need to invalidate the last line specifically.
        if range.location == textStorage?.length, !lineStorage.isEmpty {
            lineStorage.last?.data.setNeedsLayout()
        }

        layoutView?.needsLayout = true
    }

    /// Forgets the measured width of every line and lays them out again.
    ///
    /// Call this when something changes how wide every line is, such as the font or the letter spacing. Without it the
    /// document keeps the width its lines measured before the change until each one is laid out again, and a line that
    /// stays off screen never is.
    public func invalidateLineWidths() {
        lineStorage.resetWidths()
        setNeedsLayout()
    }

    public func setNeedsLayout() {
        invalidateGeometry(from: 0)
        needsLayout = true
        visibleLineIds.removeAll(keepingCapacity: true)
        layoutView?.needsLayout = true
    }

    /// Records that the geometry of the text in `range` may no longer be where it was last measured.
    ///
    /// Reported to the delegate by the next layout pass, through ``TextLayoutUpdate/invalidatedRange``.
    /// - Parameter range: The range of text whose geometry may have moved.
    func invalidateGeometry(in range: NSRange) {
        guard let pending = pendingGeometryInvalidation else {
            pendingGeometryInvalidation = range
            return
        }
        pendingGeometryInvalidation = NSRange(
            start: Swift.min(pending.location, range.location),
            end: Swift.max(pending.max, range.max)
        )
    }

    /// Records that the geometry of every offset at or after `offset` may no longer be where it was last measured.
    ///
    /// The span has no upper bound, rather than ending at the document's length. An edit moves the text after it
    /// without moving the ranges anything stored beforehand, so a range that now sits past the end of a shortened
    /// document is still part of what the edit changed, and hearing about it is the only way it can learn that the
    /// text it marked is gone.
    /// - Parameter offset: The first offset whose geometry may have moved.
    func invalidateGeometry(from offset: Int) {
        invalidateGeometry(in: NSRange(location: offset, length: Int.max - offset))
    }
}
