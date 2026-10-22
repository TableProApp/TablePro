//
//  SelectionManipulation+Vertical.swift
//  TableProTextEngine
//
//  Created by Khan Winter on 5/11/24.
//

import Foundation

package extension TextSelectionManager {
    // MARK: - Vertical Methods

    /// Extends a selection from the given offset vertically to the destination.
    /// - Parameters:
    ///   - offset: The offset to extend from.
    ///   - destination: The destination to extend to.
    ///   - up: Set to true if extending up.
    ///   - suggestedXPos: The suggested x position to stick to.
    /// - Returns: The range of the extended selection.
    func extendSelectionVertical(
        from offset: Int,
        destination: Destination,
        up: Bool,
        suggestedXPos: CGFloat?
    ) -> NSRange {
        // If moving up and on the first line, jump to the start of the document.
        // If moving down and on the last line, jump to the end of the document.
        // `textLineForOffset` returns the last line for `offset == length`, which `NSRange.contains`
        // (half-open) misses — that's the end-of-document caret case.
        if let currentLine = layoutManager?.textLineForOffset(offset) {
            if up && currentLine.data.id == layoutManager?.lineStorage.first?.data.id {
                return NSRange(location: 0, length: offset)
            }
            if !up && currentLine.data.id == layoutManager?.lineStorage.last?.data.id {
                return NSRange(start: offset, end: textStorage?.length ?? offset)
            }
        }

        switch destination {
        case .character:
            return extendSelectionVerticalCharacter(from: offset, up: up, suggestedXPos: suggestedXPos)
        case .word, .line, .visualLine:
            return extendSelectionVerticalLine(from: offset, up: up)
        case .page:
            return extendSelectionPage(from: offset, delta: up ? 1 : -1, suggestedXPos: suggestedXPos)
        case .document:
            if up {
                return NSRange(location: 0, length: offset)
            } else {
                return NSRange(start: offset, end: (textStorage?.length ?? offset))
            }
        }
    }

    /// Extends the selection to the nearest character vertically.
    /// - Parameters:
    ///   - offset: The offset to extend from.
    ///   - up: Set to true if extending up.
    ///   - suggestedXPos: The suggested x position to stick to.
    /// - Returns: The range of the extended selection.
    private func extendSelectionVerticalCharacter(
        from offset: Int,
        up: Bool,
        suggestedXPos: CGFloat?
    ) -> NSRange {
        guard let point = layoutManager?.rectForOffset(offset)?.origin,
              let newOffset = layoutManager?.textOffsetAtPoint(
                CGPoint(
                    x: suggestedXPos ?? point.x,
                    y: point.y - (layoutManager?.estimateLineHeight() ?? 2.0) / 2 * (up ? 1 : -3)
                )
              ) else {
            return NSRange(location: offset, length: 0)
        }

        return NSRange(
            location: up ? newOffset : offset,
            length: up ? offset - newOffset : newOffset - offset
        )
    }

    // Paragraph start or end, staying put once there, as `NSTextView` and Emacs's C-a and C-e do.
    private func extendSelectionVerticalLine(
        from offset: Int,
        up: Bool
    ) -> NSRange {
        // The whole line, not the line fragment, when the line wraps.
        guard let line = layoutManager?.textLineForOffset(offset) else {
            return NSRange(location: offset, length: 0)
        }
        if up {
            return NSRange(start: line.range.location, end: max(offset, line.range.location))
        }
        let lineEndingLength = textStorage
            .flatMap { $0.substring(from: line.range) }
            .flatMap(LineEnding.init(line:))?.length ?? 0
        return NSRange(start: offset, end: max(offset, line.range.max - lineEndingLength))
    }

    /// Extends a selection one "page" long.
    /// - Parameters:
    ///   - offset: The location to start extending the selection from.
    ///   - delta: The direction the selection should be extended. `1` for forwards, `-1` for backwards.
    /// - Returns: The range of the extended selection.
    private func extendSelectionPage(from offset: Int, delta: Int, suggestedXPos: CGFloat?) -> NSRange {
        guard let textView = textView,
              let layoutManager,
              let currentYPos = layoutManager.rectForOffset(offset)?.origin.y else {
            return NSRange(location: offset, length: 0)
        }

        let pageHeight = textView.visibleRect.height

        // Grab the line where the next selection should be. Then use the suggestedXPos to find where in the line the
        // selection should be extended to.
        layoutManager.layoutLines(
            in: NSRect(x: 0, y: currentYPos, width: layoutManager.maxLineWidth, height: pageHeight)
        )
        guard let nextPageOffset = layoutManager.textOffsetAtPoint(CGPoint(
            x: suggestedXPos ?? 0,
            y: min(textView.frame.height, max(0, currentYPos + (delta > 0 ? -pageHeight : pageHeight)))
        )) else {
            return NSRange(location: offset, length: 0)
        }

        if delta > 0 {
            return NSRange(start: nextPageOffset, end: offset)
        } else {
            return NSRange(location: offset, length: nextPageOffset - offset)
        }
    }
}
