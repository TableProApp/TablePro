//
//  TextLayoutUpdate.swift
//  TableProTextEngine
//

import Foundation

/// What one layout pass changed, handed to ``TextLayoutManagerDelegate/layoutManagerDidLayout(_:)``.
///
/// Anything drawing its own decorations over the text needs to know when the geometry beneath them moved. A redraw
/// is not that signal: AppKit draws a newly exposed strip without laying anything out, and responsive scrolling
/// draws frames the layout pass never touched. A layout pass is the signal, and this says what it did.
public struct TextLayoutUpdate: Equatable {
    /// The document span whose geometry may differ from what was last drawn, `nil` when nothing changed it.
    ///
    /// Open at the top end when an edit or a global layout change moved every offset after a point. A range stored
    /// before such an edit keeps the offsets it had, so one that now sits past the end of a shortened document is
    /// still part of what the edit changed.
    public let invalidatedRange: NSRange?

    /// The document span this pass laid out. Geometry can only be read for text inside it.
    public let laidOutRange: NSRange?

    /// The vertical span this pass laid out, in the text view's coordinates.
    public let laidOutYSpan: ClosedRange<CGFloat>

    public init(invalidatedRange: NSRange?, laidOutRange: NSRange?, laidOutYSpan: ClosedRange<CGFloat>) {
        self.invalidatedRange = invalidatedRange
        self.laidOutRange = laidOutRange
        self.laidOutYSpan = laidOutYSpan
    }
}
