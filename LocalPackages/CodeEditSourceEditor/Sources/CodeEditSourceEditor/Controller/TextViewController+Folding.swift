//
//  TextViewController+Folding.swift
//  CodeEditSourceEditor
//

import AppKit

/// A collapsed fold the pointer is over, and where its placeholder is drawn.
public struct CollapsedFoldHit: Equatable {
    /// The range of text the placeholder hides.
    ///
    /// A fold starts at the end of the line that opens it, so this range excludes `CREATE TABLE users (` and starts
    /// at the newline after it.
    public let hiddenRange: Range<Int>

    /// The whole block the fold belongs to, grown to line boundaries.
    ///
    /// A reader peeking at a fold wants the block, not the remainder of it, so this range covers the line that opens
    /// the block through the end of the line that closes it.
    public let blockRange: Range<Int>

    /// The placeholder's rect in the text view's coordinate space, for anchoring a preview.
    public let rect: CGRect
}

public extension TextViewController {
    /// Posted on the controller whenever a fold collapses or expands.
    static let foldStateDidChangeNotification = Notification.Name(
        "CodeEditSourceEditor.foldStateDidChangeNotification"
    )

    /// The collapsed fold under a point in the text view, if there is one.
    ///
    /// Every character a placeholder hides is drawn as that one placeholder, so a point that resolves to an offset
    /// inside the folded range is a point over the placeholder. Text after the placeholder resolves past the range.
    func collapsedFold(at point: CGPoint) -> CollapsedFoldHit? {
        placeholderHover(at: point)?.hit
    }

    /// The document's plain text over a range, capped so reading a huge region stays cheap.
    ///
    /// The text arrives unstyled on purpose. Attributes in the text storage only exist for ranges the highlighter has
    /// laid out, and a collapsed fold is by definition not laid out, so anything reading them back would style the
    /// lines the reader has already seen and leave the rest plain. A caller that wants the text highlighted has to
    /// highlight it itself.
    func documentText(in range: Range<Int>, limit: Int) -> String? {
        guard let storage = textView?.textStorage else { return nil }
        let start = max(0, min(range.lowerBound, storage.length))
        let end = max(start, min(range.upperBound, storage.length))
        guard end > start else { return nil }
        return (storage.string as NSString).substring(with: NSRange(location: start, length: min(end - start, limit)))
    }

    /// The range of every fold in the document, collapsed or not, ordered by start position.
    var foldRanges: [Range<Int>] {
        foldModel?.getFolds(in: textView.documentRange.intRange).map(\.range) ?? []
    }

    /// The ranges of every collapsed fold, suitable for persisting and replaying with ``restoreCollapsedFolds(_:)``.
    var collapsedFoldRanges: [Range<Int>] {
        foldModel?.collapsedFoldRanges() ?? []
    }

    /// Collapses the outermost folds in the document.
    func foldAll() {
        foldModel?.setAllCollapsed(true)
    }

    /// Expands every collapsed fold in the document.
    func unfoldAll() {
        foldModel?.setAllCollapsed(false)
    }

    /// Collapses the fold at a line, or expands it when it is already collapsed.
    /// - Parameter lineNumber: The line to toggle, zero-indexed.
    /// - Returns: Whether a fold was found at that line.
    @discardableResult
    func toggleFold(atLine lineNumber: Int) -> Bool {
        guard let model = foldModel, let fold = model.getCachedFoldAt(lineNumber: lineNumber) else { return false }
        model.setCollapsed(!model.isCollapsed(fold), for: fold)
        return true
    }

    /// Toggles the innermost fold containing the cursor.
    /// - Returns: Whether a fold was found at the cursor.
    @discardableResult
    func toggleFoldAtCursor() -> Bool {
        guard let offset = cursorPositions.first?.range.location,
              let line = textView.layoutManager.textLineForOffset(offset) else { return false }
        return toggleFold(atLine: line.index)
    }

    /// Whether a fold containing the cursor is currently collapsed. `nil` when there is no fold at the cursor.
    func foldStateAtCursor() -> Bool? {
        guard let model = foldModel,
              let offset = cursorPositions.first?.range.location,
              let line = textView.layoutManager.textLineForOffset(offset),
              let fold = model.getCachedFoldAt(lineNumber: line.index) else { return nil }
        return model.isCollapsed(fold)
    }

    /// Collapses the folds matching the given ranges once they have been calculated.
    ///
    /// Ranges that no longer match a fold are dropped, so a document edited outside the editor restores what it can
    /// instead of failing.
    func restoreCollapsedFolds(_ ranges: [Range<Int>]) {
        foldModel?.restoreCollapsedFolds(ranges)
    }

    internal var foldModel: LineFoldModel? {
        gutterView?.foldingRibbon.model
    }
}

// MARK: - Hover

internal extension TextViewController {
    /// The collapsed fold's placeholder under a point, with the fold it stands for.
    ///
    /// The placeholder carries its own fold, so resolving the pointer to an attachment resolves it to a fold too. No
    /// second lookup against the cache is needed, and the two can never disagree about which fold was hit.
    func placeholderHover(at point: CGPoint) -> LineFoldModel.PlaceholderHover? {
        guard let textView, let layoutManager = textView.layoutManager,
              let offset = layoutManager.textOffsetAtPoint(point) else { return nil }

        let overlapping = layoutManager.attachments.getAttachmentsOverlapping(NSRange(location: offset, length: 1))
        guard let attachment = overlapping.first(where: { $0.attachment is LineFoldPlaceholder }),
              let placeholder = attachment.attachment as? LineFoldPlaceholder,
              let caret = layoutManager.rectForOffset(attachment.range.location) else { return nil }

        // `rectForOffset` reports a caret, which has no width. The placeholder's own width makes the hit a rect that
        // covers what the reader sees, which is what a popover needs to anchor to.
        let hidden = attachment.range.intRange
        return LineFoldModel.PlaceholderHover(
            fold: placeholder.fold,
            hit: CollapsedFoldHit(
                hiddenRange: hidden,
                blockRange: blockRange(covering: hidden),
                rect: CGRect(
                    x: caret.minX,
                    y: caret.minY,
                    width: placeholder.width,
                    height: caret.height
                )
            )
        )
    }

    /// Tells every coordinator which collapsed fold the pointer came to rest on, or that it left one.
    func foldHoverDidChange(_ hit: CollapsedFoldHit?) {
        for coordinator in textCoordinators.values() {
            coordinator.textViewDidChangeHoveredFold(controller: self, hit: hit)
        }
    }

    /// Grows a range to cover whole lines.
    ///
    /// This reads the string rather than the layout manager because the lines inside a collapsed fold have no layout
    /// to ask: the fold hides them by zeroing their heights, and the layout manager resolves offsets through visible
    /// positions only. `lineRange(for:)` answers from the text itself, so it is correct whether or not a line has
    /// ever been laid out.
    func blockRange(covering range: Range<Int>) -> Range<Int> {
        guard let storage = textView?.textStorage, storage.length > 0 else { return range }
        let string = storage.string as NSString
        let lower = max(0, min(range.lowerBound, string.length))
        let upper = max(lower, min(range.upperBound, string.length))

        let first = string.lineRange(for: NSRange(location: lower, length: 0))
        let last = upper > lower
            ? string.lineRange(for: NSRange(location: max(lower, upper - 1), length: 0))
            : first
        return first.location..<max(first.location, last.upperBound)
    }
}
