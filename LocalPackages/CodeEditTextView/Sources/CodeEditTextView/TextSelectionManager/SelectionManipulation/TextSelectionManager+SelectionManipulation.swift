//
//  TextSelectionManager+SelectionManipulation.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 8/26/23.
//

import AppKit

public extension TextSelectionManager {
    // MARK: - Range Of Selection

    /// Creates a range for a new selection given a starting point, direction, and destination.
    /// - Parameters:
    ///   - offset: The location to start the selection from.
    ///   - direction: The direction the selection should be created in.
    ///   - destination: Determines how far the selection is.
    ///   - decomposeCharacters: Set to `true` to treat grapheme clusters as individual characters.
    ///   - suggestedXPos: The suggested x position to stick to.
    /// - Returns: A range of a new selection based on the direction and destination.
    func rangeOfSelection(
        from offset: Int,
        direction: Direction,
        destination: Destination,
        decomposeCharacters: Bool = false,
        suggestedXPos: CGFloat? = nil
    ) -> NSRange {
        var range: NSRange
        switch direction {
        case .backward:
            guard offset > 0 else { return NSRange(location: offset, length: 0) } // Can't go backwards beyond 0
            range = extendSelectionHorizontal(
                from: offset,
                destination: destination,
                delta: -1,
                decomposeCharacters: decomposeCharacters
            )
        case .forward:
            range = extendSelectionHorizontal(
                from: offset,
                destination: destination,
                delta: 1,
                decomposeCharacters: decomposeCharacters
            )
        case .up:
            range = extendSelectionVertical(
                from: offset,
                destination: destination,
                up: true,
                suggestedXPos: suggestedXPos
            )
        case .down:
            range = extendSelectionVertical(
                from: offset,
                destination: destination,
                up: false,
                suggestedXPos: suggestedXPos
            )
        }

        // Extend ranges to include attachments.
        if let attachments = layoutManager?.attachments.getAttachmentsOverlapping(range) {
            attachments.forEach { textAttachment in
                range.formUnion(textAttachment.range)
            }
        }

        return range
    }
}
