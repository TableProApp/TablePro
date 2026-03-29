//
//  TextViewController+LineOperations.swift
//  CodeEditSourceEditor
//
//  Line-level editing operations: duplicate, delete.
//

import AppKit
import CodeEditTextView

extension TextViewController {
    /// Duplicates the current line(s) below the selection (Cmd+D).
    func duplicateLine() {
        guard let selection = textView.selectionManager.textSelections.first else { return }
        guard let lineIndexes = getOverlappingLines(for: selection.range),
              let firstLine = textView.layoutManager.textLineForIndex(lineIndexes.lowerBound),
              let lastLine = textView.layoutManager.textLineForIndex(lineIndexes.upperBound) else {
            return
        }

        let fullRange = NSRange(
            location: firstLine.range.location,
            length: lastLine.range.upperBound - firstLine.range.location
        )
        guard let text = textView.textStorage.substring(from: fullRange) else { return }

        textView.undoManager?.beginUndoGrouping()

        // If line includes trailing \n, insert the text as-is after the line.
        // If no trailing \n (last line), prepend \n before inserting.
        let insertText = text.hasSuffix("\n") ? text : "\n" + text
        let insertionPoint = fullRange.upperBound
        textView.replaceCharacters(in: NSRange(location: insertionPoint, length: 0), with: insertText)

        let offset = selection.range.location - fullRange.location
        let newLocation = insertionPoint + (text.hasSuffix("\n") ? 0 : 1) + offset
        setCursorPositions([CursorPosition(range: NSRange(location: newLocation, length: 0))])

        textView.undoManager?.endUndoGrouping()
    }

    /// Deletes the current line(s) (Cmd+Shift+K).
    func deleteLine() {
        guard let selection = textView.selectionManager.textSelections.first else { return }
        guard let lineIndexes = getOverlappingLines(for: selection.range),
              let firstLine = textView.layoutManager.textLineForIndex(lineIndexes.lowerBound),
              let lastLine = textView.layoutManager.textLineForIndex(lineIndexes.upperBound) else {
            return
        }

        let fullRange = NSRange(
            location: firstLine.range.location,
            length: lastLine.range.upperBound - firstLine.range.location
        )

        textView.undoManager?.beginUndoGrouping()

        textView.replaceCharacters(in: fullRange, with: "")
        let newLocation = min(fullRange.location, textView.textStorage.length)
        setCursorPositions([CursorPosition(range: NSRange(location: newLocation, length: 0))])

        textView.undoManager?.endUndoGrouping()
    }
}
