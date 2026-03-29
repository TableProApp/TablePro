//
//  TypesetContext.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 4/24/25.
//

import Foundation

/// Represents partial parsing state for typesetting a line. Used once during typesetting and then discarded.
/// Contains a few methods for appending data or popping the current line data.
struct TypesetContext {
    let documentRange: NSRange
    let displayData: TextLine.DisplayData

    /// Accumulated generated line fragments.
    var lines: [TextLineStorage<LineFragment>.BuildItem] = []
    var maxHeight: CGFloat = 0
    /// The current fragment typesetting context.
    var fragmentContext = LineFragmentTypesetContext(start: 0, width: 0.0, height: 0.0, descent: 0.0)

    /// Tracks the current position when laying out runs
    var currentPosition: Int = 0

    // MARK: - Fragment Context Modification

    /// Appends an attachment to the current ``fragmentContext``
    /// - Parameter attachment: The type-erased attachment to append.
    mutating func appendAttachment(_ attachment: AnyTextAttachment) {
        // Check if we can append this attachment to the current line
        if fragmentContext.width + attachment.width > displayData.maxWidth {
            popCurrentData()
        }

        // Add the attachment to the current line
        fragmentContext.contents.append(
            .init(data: .attachment(attachment: attachment), width: attachment.width)
        )
        fragmentContext.width += attachment.width
        fragmentContext.height = fragmentContext.height == 0 ? maxHeight : fragmentContext.height
        currentPosition += attachment.range.length
    }

    /// Appends a text range to the current ``fragmentContext``
    /// - Parameters:
    ///   - typesettingRange: The range relative to the typesetter for the current fragment context.
    ///   - lineBreak: The position that the text fragment should end at, relative to the typesetter's range.
    ///   - typesetData: Data received from the typesetter.
    mutating func appendText(typesettingRange: NSRange, lineBreak: Int, typesetData: CTLineTypesetData) {
        fragmentContext.contents.append(
            .init(data: .text(line: typesetData.ctLine), width: typesetData.width)
        )
        fragmentContext.width += typesetData.width
        fragmentContext.height = typesetData.height
        fragmentContext.descent = max(typesetData.descent, fragmentContext.descent)
        currentPosition = lineBreak + typesettingRange.location
    }

    // MARK: - Pop Fragments

    /// Pop the current fragment state into a new line fragment, and reset the fragment state.
    mutating func popCurrentData() {
        let fragment = LineFragment(
            contents: fragmentContext.contents,
            width: fragmentContext.width,
            height: fragmentContext.height,
            descent: fragmentContext.descent,
            lineHeightMultiplier: displayData.lineHeightMultiplier
        )
        lines.append(
            .init(data: fragment, length: currentPosition - fragmentContext.start, height: fragment.scaledHeight)
        )
        maxHeight = max(maxHeight, fragment.scaledHeight)

        fragmentContext.clear()
        fragmentContext.start = currentPosition
    }
}
