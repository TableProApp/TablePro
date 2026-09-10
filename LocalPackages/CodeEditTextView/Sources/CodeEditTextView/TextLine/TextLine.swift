//
//  TextLine.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 6/21/23.
//

import Foundation
import AppKit

/// Represents a displayable line of text.
public final class TextLine: Identifiable, Equatable {
    public let id: UUID = UUID()
    private var needsLayout: Bool = true
    var maxWidth: CGFloat?
    private(set) var typesetter: Typesetter = Typesetter()

    /// The line fragments contained by this text line.
    public var lineFragments: TextLineStorage<LineFragment> {
        typesetter.lineFragments
    }

    /// Marks this line as needing layout and clears all typesetting data.
    public func setNeedsLayout() {
        needsLayout = true
        typesetter = Typesetter()
    }

    /// Determines if the line needs to be laid out again.
    /// - Parameter maxWidth: The new max width to check.
    /// - Returns: True, if this line has been marked as needing layout using ``TextLine/setNeedsLayout()`` or if the
    ///            line needs to find new line breaks due to a new constraining width.
    func needsLayout(maxWidth: CGFloat) -> Bool {
        needsLayout // Force layout
        || (
            // Both max widths we're comparing are finite
            maxWidth.isFinite
            && (self.maxWidth ?? 0.0).isFinite
            && maxWidth != (self.maxWidth ?? 0.0)
        )
    }

    /// Prepares the line for display, generating all potential line breaks and calculating the real height of the line.
    /// - Parameters:
    ///   - displayData: Information required to display a text line.
    ///   - range: The range this text range represents in the entire document.
    ///   - stringRef: A reference to the string storage for the document.
    ///   - markedRanges: Any marked ranges in the line.
    ///   - attachments: Any attachments overlapping the line range.
    public func prepareForDisplay(
        displayData: DisplayData,
        range: NSRange,
        stringRef: NSTextStorage,
        markedRanges: MarkedRanges?,
        attachments: [AnyTextAttachment]
    ) {
        // The line storage can be longer than the string it indexes for as long as an edit is in
        // flight, and slicing with a range from the far side of that raises. Leaving `needsLayout`
        // set means the line is typeset again once the two agree.
        guard let documentRange = range.resolved(inDocumentOfLength: stringRef.length),
              documentRange == range else {
            return
        }
        let string = stringRef.attributedSubstring(from: documentRange)
        let maxWidth = typesetter.typeset(
            string,
            documentRange: documentRange,
            displayData: displayData,
            markedRanges: markedRanges,
            attachments: attachments
        )
        self.maxWidth = displayData.maxWidth
        needsLayout = false
    }

    public static func == (lhs: TextLine, rhs: TextLine) -> Bool {
        lhs.id == rhs.id
    }

    /// Contains all required data to perform a typeset and layout operation on a text line.
    public struct DisplayData {
        public let maxWidth: CGFloat
        public let lineHeightMultiplier: CGFloat
        public let estimatedLineHeight: CGFloat
        public let breakStrategy: LineBreakStrategy

        public init(
            maxWidth: CGFloat,
            lineHeightMultiplier: CGFloat,
            estimatedLineHeight: CGFloat,
            breakStrategy: LineBreakStrategy = .character
        ) {
            self.maxWidth = maxWidth
            self.lineHeightMultiplier = lineHeightMultiplier
            self.estimatedLineHeight = estimatedLineHeight
            self.breakStrategy = breakStrategy
        }
    }
}
