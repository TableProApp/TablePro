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

    override func draw(_ dirtyRect: NSRect) {
        drawStatementHighlight(in: dirtyRect)
        super.draw(dirtyRect)
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
