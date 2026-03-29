//
//  TextLayoutManager+Iterator.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 8/21/23.
//

import Foundation

public extension TextLayoutManager {
    /// Iterate over all visible lines.
    ///
    /// Visible lines are any lines contained by the rect returned by ``TextLayoutManagerDelegate/visibleRect`` or,
    /// if there is no delegate from `0` to the estimated document height.
    ///
    /// - Returns: An iterator to iterate through all visible lines.
    func visibleLines() -> YPositionIterator {
        let visibleRect = delegate?.visibleRect ?? NSRect(
            x: 0,
            y: 0,
            width: 0,
            height: estimatedHeight()
        )
        return YPositionIterator(minY: max(visibleRect.minY, 0), maxY: max(visibleRect.maxY, 0), layoutManager: self)
    }

    /// Iterate over all lines in the y position range.
    /// - Parameters:
    ///   - minY: The minimum y position to begin at.
    ///   - maxY: The maximum y position to iterate to.
    /// - Returns: An iterator that will iterate through all text lines in the y position range.
    func linesStartingAt(_ minY: CGFloat, until maxY: CGFloat) -> YPositionIterator {
        YPositionIterator(minY: minY, maxY: maxY, layoutManager: self)
    }
    /// Iterate over all lines that overlap a document range.
    /// - Parameters:
    ///   - range: The range in the document to iterate over.
    /// - Returns: An iterator for lines in the range. The iterator returns lines that *overlap* with the range.
    ///            Returned lines may extend slightly before or after the queried range.
    func linesInRange(_ range: NSRange) -> RangeIterator {
        RangeIterator(range: range, layoutManager: self)
    }

    /// This iterator iterates over "visible" text positions that overlap a range of vertical `y` positions
    /// using ``TextLayoutManager/determineVisiblePosition(for:)``.
    ///
    /// Next elements are retrieved lazily. Additionally, this iterator uses a stable `index` rather than a y position
    /// or a range to fetch the next line. This means the line storage can be updated during iteration.
    struct YPositionIterator: LazySequenceProtocol, IteratorProtocol {
        typealias TextLinePosition = TextLineStorage<TextLine>.TextLinePosition

        private weak var layoutManager: TextLayoutManager?
        private let minY: CGFloat
        private let maxY: CGFloat
        private var currentPosition: (position: TextLinePosition, indexRange: ClosedRange<Int>)?

        init(minY: CGFloat, maxY: CGFloat, layoutManager: TextLayoutManager) {
            self.minY = minY
            self.maxY = maxY
            self.layoutManager = layoutManager
        }

        /// Iterates over the "visible" text positions.
        ///
        /// See documentation on ``TextLayoutManager/determineVisiblePosition(for:)`` for details.
        public mutating func next() -> TextLineStorage<TextLine>.TextLinePosition? {
            if let currentPosition {
                guard let nextPosition = layoutManager?.lineStorage.getLine(
                    atIndex: currentPosition.indexRange.upperBound + 1
                ), nextPosition.yPos < maxY else {
                    return nil
                }
                self.currentPosition = layoutManager?.determineVisiblePosition(for: nextPosition)
                return self.currentPosition?.position
            } else if let position = layoutManager?.lineStorage.getLine(atPosition: minY) {
                currentPosition = layoutManager?.determineVisiblePosition(for: position)
                return currentPosition?.position
            }

            return nil
        }
    }

    /// This iterator iterates over "visible" text positions that overlap a document using
    /// ``TextLayoutManager/determineVisiblePosition(for:)``.
    ///
    /// Next elements are retrieved lazily. Additionally, this iterator uses a stable `index` rather than a y position
    /// or a range to fetch the next line. This means the line storage can be updated during iteration.
    struct RangeIterator: LazySequenceProtocol, IteratorProtocol {
        typealias TextLinePosition = TextLineStorage<TextLine>.TextLinePosition

        private weak var layoutManager: TextLayoutManager?
        private let range: NSRange
        private var currentPosition: (position: TextLinePosition, indexRange: ClosedRange<Int>)?

        init(range: NSRange, layoutManager: TextLayoutManager) {
            self.range = range
            self.layoutManager = layoutManager
        }

        /// Iterates over the "visible" text positions.
        ///
        /// See documentation on ``TextLayoutManager/determineVisiblePosition(for:)`` for details.
        public mutating func next() -> TextLineStorage<TextLine>.TextLinePosition? {
            if let currentPosition {
                guard let nextPosition = layoutManager?.lineStorage.getLine(
                    atIndex: currentPosition.indexRange.upperBound + 1
                ), nextPosition.range.location < range.max else {
                    return nil
                }
                self.currentPosition = layoutManager?.determineVisiblePosition(for: nextPosition)
                return self.currentPosition?.position
            } else if let position = layoutManager?.lineStorage.getLine(atOffset: range.location) {
                currentPosition = layoutManager?.determineVisiblePosition(for: position)
                return currentPosition?.position
            }

            return nil
        }
    }

    /// Determines the “visible” line position by merging any consecutive lines
    /// that are spanned by text attachments. If an attachment overlaps beyond the
    /// bounds of the original line, this method will extend the returned range to
    /// cover the full span of those attachments (and recurse if further attachments
    /// cross into newly included lines).
    ///
    /// For example, given the following:  *(`[` == attachment start, `]` == attachment end)*
    /// ```
    /// Line 1
    /// Line[ 2
    /// Line 3
    /// Line] 4
    /// ```
    /// If you start at the position for “Line 2”, the first and last attachments
    /// overlap lines 2–4, so this method will extend the range to cover lines 2–4
    /// and return a position whose `range` spans the entire attachment.
    ///
    /// # Why recursion?
    ///
    /// When an attachment extends the visible range, it may pull in new lines that themselves overlap other
    /// attachments. A simple one‐pass merge wouldn’t catch those secondary overlaps. By calling
    /// determineVisiblePosition again on the newly extended range, we ensure that all cascading attachments—no matter
    /// how many lines they span—are folded into a single, coherent TextLinePosition before returning.
    ///
    /// - Parameter originalPosition: The initial `TextLinePosition` to inspect.
    ///   Pass in the position you got from `lineStorage.getLine(atOffset:)` or similar.
    /// - Returns: A tuple containing `position`: A `TextLinePosition` whose `range` and `index` have been
    ///            adjusted to include any attachment‐spanned lines.. `indexRange`: A `ClosedRange<Int>` listing all of
    ///            the line indices that are now covered by the returned position.
    ///   Returns `nil` if `originalPosition` is `nil`.
    func determineVisiblePosition(
        for originalPosition: TextLineStorage<TextLine>.TextLinePosition?
    ) -> (position: TextLineStorage<TextLine>.TextLinePosition, indexRange: ClosedRange<Int>)? {
        guard let originalPosition else { return nil }
        return determineVisiblePositionRecursively(
            for: (originalPosition, originalPosition.index...originalPosition.index),
            recursionDepth: 0
        )
    }

    /// Private implementation of ``TextLayoutManager/determineVisiblePosition(for:)``.
    ///
    /// Separated for readability. This method does not have an optional parameter, and keeps track of a recursion
    /// depth.
    private func determineVisiblePositionRecursively(
        for originalPosition: (position: TextLineStorage<TextLine>.TextLinePosition, indexRange: ClosedRange<Int>),
        recursionDepth: Int
    ) -> (position: TextLineStorage<TextLine>.TextLinePosition, indexRange: ClosedRange<Int>)? {
        // Arbitrary max recursion depth. Ensures we don't spiral into in an infinite recursion.
        guard recursionDepth < 10 else {
            logger.warning("Visible position recursed for over 10 levels, returning early.")
            return originalPosition
        }

        let attachments = attachments.getAttachmentsOverlapping(originalPosition.position.range)
        guard let firstAttachment = attachments.first, let lastAttachment = attachments.last else {
            // No change, either no attachments or attachment doesn't span multiple lines.
            return originalPosition
        }

        var minIndex = originalPosition.indexRange.lowerBound
        var maxIndex = originalPosition.indexRange.upperBound
        var newPosition = originalPosition.position

        if firstAttachment.range.location < originalPosition.position.range.location,
           let extendedLinePosition = lineStorage.getLine(atOffset: firstAttachment.range.location) {
            newPosition = TextLineStorage<TextLine>.TextLinePosition(
                data: extendedLinePosition.data,
                range: NSRange(start: extendedLinePosition.range.location, end: newPosition.range.max),
                yPos: extendedLinePosition.yPos,
                height: extendedLinePosition.height,
                index: extendedLinePosition.index
            )
            minIndex = min(minIndex, newPosition.index)
        }

        if lastAttachment.range.max > originalPosition.position.range.max,
           let extendedLinePosition = lineStorage.getLine(atOffset: lastAttachment.range.max) {
            newPosition = TextLineStorage<TextLine>.TextLinePosition(
                data: newPosition.data,
                range: NSRange(start: newPosition.range.location, end: extendedLinePosition.range.max),
                yPos: newPosition.yPos,
                height: newPosition.height,
                index: newPosition.index // We want to keep the minimum index.
            )
            maxIndex = max(maxIndex, extendedLinePosition.index)
        }

        if firstAttachment.range.location == newPosition.range.location {
            minIndex = max(minIndex, 0)
        }

        if lastAttachment.range.max == newPosition.range.max {
            maxIndex = min(maxIndex, lineStorage.count - 1)
        }

        // Base case, we haven't updated anything
        if minIndex...maxIndex == originalPosition.indexRange {
            return (newPosition, minIndex...maxIndex)
        } else {
            // Recurse, to make sure we combine all necessary lines.
            return determineVisiblePositionRecursively(
                for: (newPosition, minIndex...maxIndex),
                recursionDepth: recursionDepth + 1
            )
        }
    }
}
