//
//  SourceEditorTextView.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 7/23/25.
//

import AppKit
import CodeEditTextView

final class SourceEditorTextView: TextView {
    var additionalCursorRects: [(NSRect, NSCursor)] = []

    /// The span of the statement the caret sits in, painted as a band behind the text.
    ///
    /// This is a decoration and never a selection. Marking a statement by selecting it, which some editors do, means
    /// the reader's next keystroke replaces it.
    var statementHighlightRange: NSRange? {
        didSet {
            guard statementHighlightRange != oldValue else { return }
            needsDisplay = true
        }
    }

    /// The colour of the statement band. Fully transparent by default, so an editor that never sets a range and a
    /// theme that never sets a colour both paint nothing.
    var statementHighlightColor: NSColor = .clear {
        didSet {
            guard statementHighlightColor != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Answers where the statement before or after an offset starts, or `nil` when the host has not supplied one.
    ///
    /// The text system has a paragraph selection verb and no paragraph move verb, so the only standard selectors this
    /// view can implement over statements are the two `AndModifySelection:` ones below. They are dead in an editor
    /// whose host leaves this unset, which is every editor here that is not showing SQL: the JSON viewer, the DDL
    /// view, the trigger editor, the SQL preview and the AI chat code blocks all use this class.
    var statementBoundaryProvider: ((_ offset: Int, _ forward: Bool) -> Int?)?

    override func draw(_ dirtyRect: NSRect) {
        drawStatementHighlight(in: dirtyRect)
        super.draw(dirtyRect)
    }

    /// `Option+Shift+Up`, per AppKit's own standard key bindings.
    override func moveParagraphBackwardAndModifySelection(_ sender: Any?) {
        guard extendSelectionToStatement(forward: false) else {
            super.moveParagraphBackwardAndModifySelection(sender)
            return
        }
    }

    /// `Option+Shift+Down`, per AppKit's own standard key bindings.
    override func moveParagraphForwardAndModifySelection(_ sender: Any?) {
        guard extendSelectionToStatement(forward: true) else {
            super.moveParagraphForwardAndModifySelection(sender)
            return
        }
    }

    /// Grows or shrinks the selection by a statement, keeping the end the reader started from fixed.
    ///
    /// The fixed end is the selection's own `pivot`, the same thing every other modifying motion in the text system
    /// uses. Deriving it from the direction instead would make the two keys both grow the selection rather than undo
    /// each other, because shrinking means moving the head back past the pivot.
    ///
    /// Returns `false` when there is no statement to reach, so the caller falls back to whatever the text system
    /// would have done and this stays inert wherever no statement source is set.
    private func extendSelectionToStatement(forward: Bool) -> Bool {
        guard let provider = statementBoundaryProvider,
              let selection = selectionManager.textSelections.first else {
            return false
        }

        let anchor = selection.pivot ?? (forward ? selection.range.lowerBound : selection.range.upperBound)
        let head = selection.range.lowerBound == anchor ? selection.range.upperBound : selection.range.lowerBound
        guard let destination = provider(head, forward) else { return false }

        let lower = min(anchor, destination)
        let range = NSRange(location: lower, length: max(anchor, destination) - lower)
        selectionManager.setSelectedRange(range)
        selectionManager.textSelections.first?.pivot = anchor
        scrollSelectionToVisible()
        return true
    }

    /// Painted before `super`, which is what draws the caret line highlight and the selection, so those two land on
    /// top of the band rather than under it.
    ///
    /// The text itself is drawn by the line fragment views above this one, so nothing painted here can cover it.
    /// That is the same reason the caret line highlight can be filled rather than blended.
    private func drawStatementHighlight(in dirtyRect: NSRect) {
        guard let range = statementHighlightRange,
              range.length > 0,
              statementHighlightColor.alphaComponent > 0,
              let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        context.saveGState()
        context.setFillColor(statementHighlightColor.safeCGColor)
        for rect in layoutManager.rectsFor(range: range) where rect.intersects(dirtyRect) {
            context.fill(rect.pixelAligned)
        }
        context.restoreGState()
    }

    override func resetCursorRects() {
        discardCursorRects()
        super.resetCursorRects()
        additionalCursorRects.forEach { (rect, cursor) in
            addCursorRect(rect, cursor: cursor)
        }
    }
}
