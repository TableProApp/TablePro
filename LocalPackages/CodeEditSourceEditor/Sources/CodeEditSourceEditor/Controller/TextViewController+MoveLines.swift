//
//  TextViewController+MoveLines.swift
//  CodeEditSourceEditor
//
//  Created by Bogdan Belogurov on 01/06/2025.
//

import Foundation

extension TextViewController {
    /// Moves the selected lines up by one line.
    public func moveLinesUp() {
        guard !cursorPositions.isEmpty else { return }
        guard let selection = textView.selectionManager.textSelections.first,
              let lineIndexes = getOverlappingLines(for: selection.range) else { return }
        let firstIndex = lineIndexes.lowerBound
        guard firstIndex > 0 else { return }

        guard let prevLine = textView.layoutManager.textLineForIndex(firstIndex - 1),
              let firstSelectedLine = textView.layoutManager.textLineForIndex(firstIndex),
              let lastSelectedLine = textView.layoutManager.textLineForIndex(lineIndexes.upperBound) else {
            return
        }

        // Combined range: previous line + selected lines
        let combinedRange = NSRange(
            location: prevLine.range.location,
            length: lastSelectedLine.range.upperBound - prevLine.range.location
        )
        guard let combinedText = textView.textStorage.substring(from: combinedRange) else { return }

        // Split into previous line text and selected lines text (UTF-16 safe)
        let selectedStart = firstSelectedLine.range.location - prevLine.range.location
        let nsCombined = combinedText as NSString
        let prevText = nsCombined.substring(to: selectedStart)
        let selectedText = nsCombined.substring(from: selectedStart)

        // Ensure both parts have proper newline handling
        let newText: String
        if selectedText.hasSuffix("\n") {
            newText = selectedText + prevText
        } else if prevText.hasSuffix("\n") {
            // Selected text is last line (no trailing \n), prev has \n
            newText = selectedText + "\n" + String(prevText.dropLast())
        } else {
            newText = selectedText + "\n" + prevText
        }

        textView.undoManager?.beginUndoGrouping()
        textView.replaceCharacters(in: combinedRange, with: newText)

        // Place cursor at the start of the moved line
        setCursorPositions(
            [CursorPosition(range: NSRange(location: prevLine.range.location, length: 0))],
            scrollToVisible: true
        )
        textView.undoManager?.endUndoGrouping()
    }

    /// Moves the selected lines down by one line.
    public func moveLinesDown() {
        guard !cursorPositions.isEmpty else { return }
        guard let selection = textView.selectionManager.textSelections.first,
              let lineIndexes = getOverlappingLines(for: selection.range) else { return }
        let lastIndex = lineIndexes.upperBound
        guard lastIndex + 1 < textView.layoutManager.lineCount else { return }

        guard let firstSelectedLine = textView.layoutManager.textLineForIndex(lineIndexes.lowerBound),
              let lastSelectedLine = textView.layoutManager.textLineForIndex(lastIndex),
              let nextLine = textView.layoutManager.textLineForIndex(lastIndex + 1),
              nextLine.range.length > 0 else {
            return
        }

        // Combined range: selected lines + next line
        let combinedRange = NSRange(
            location: firstSelectedLine.range.location,
            length: nextLine.range.upperBound - firstSelectedLine.range.location
        )
        guard let combinedText = textView.textStorage.substring(from: combinedRange) else { return }

        // Split into selected lines text and next line text (UTF-16 safe)
        let selectedLength = lastSelectedLine.range.upperBound - firstSelectedLine.range.location
        let nsCombined = combinedText as NSString
        let selectedText = nsCombined.substring(to: selectedLength)
        let nextText = nsCombined.substring(from: selectedLength)

        // Ensure both parts have proper newline handling
        let newText: String
        if nextText.hasSuffix("\n") {
            newText = nextText + selectedText
        } else if selectedText.hasSuffix("\n") {
            newText = nextText + "\n" + String(selectedText.dropLast())
        } else {
            newText = nextText + "\n" + selectedText
        }

        textView.undoManager?.beginUndoGrouping()
        textView.replaceCharacters(in: combinedRange, with: newText)

        // Place cursor at the start of the moved line in its new position
        let nextLen = (nextText as NSString).length + (nextText.hasSuffix("\n") ? 0 : 1)
        let newLocation = firstSelectedLine.range.location + nextLen
        setCursorPositions(
            [CursorPosition(range: NSRange(location: newLocation, length: 0))],
            scrollToVisible: true
        )
        textView.undoManager?.endUndoGrouping()
    }
}
