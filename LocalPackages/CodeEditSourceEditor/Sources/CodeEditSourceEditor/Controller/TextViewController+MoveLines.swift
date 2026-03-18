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

        textView.undoManager?.beginUndoGrouping()

        textView.editSelections { textView, selection in
            guard let lineIndexes = getOverlappingLines(for: selection.range) else { return }
            let lowerBound = lineIndexes.lowerBound
            guard lowerBound > .zero,
                  let prevLineInfo = textView.layoutManager.textLineForIndex(lowerBound - 1),
                  let prevString = textView.textStorage.substring(from: prevLineInfo.range),
                  let lastSelectedString = textView.layoutManager.textLineForIndex(lineIndexes.upperBound) else {
                return
            }

            textView.insertString(prevString, at: lastSelectedString.range.upperBound)
            textView.replaceCharacters(in: [prevLineInfo.range], with: String())

            let rangeToSelect = NSRange(
                start: prevLineInfo.range.lowerBound,
                end: lastSelectedString.range.location - prevLineInfo.range.length + lastSelectedString.range.length
            )

            setCursorPositions([CursorPosition(range: rangeToSelect)], scrollToVisible: true)
        }

        textView.undoManager?.endUndoGrouping()
    }

    /// Moves the selected lines down by one line.
    public func moveLinesDown() {
        guard !cursorPositions.isEmpty else { return }

        textView.undoManager?.beginUndoGrouping()

        textView.editSelections { textView, selection in
            guard let lineIndexes = getOverlappingLines(for: selection.range) else { return }
            let totalLines = textView.layoutManager.lineCount
            let upperBound = lineIndexes.upperBound
            guard upperBound + 1 < totalLines,
                  let nextLineInfo = textView.layoutManager.textLineForIndex(upperBound + 1),
                  let nextString = textView.textStorage.substring(from: nextLineInfo.range),
                  let firstSelectedString = textView.layoutManager.textLineForIndex(lineIndexes.lowerBound) else {
                return
            }

            textView.replaceCharacters(in: [nextLineInfo.range], with: String())
            textView.insertString(nextString, at: firstSelectedString.range.lowerBound)

            let rangeToSelect = NSRange(
                start: firstSelectedString.range.location + nextLineInfo.range.length,
                end: nextLineInfo.range.upperBound
            )

            setCursorPositions([CursorPosition(range: rangeToSelect)], scrollToVisible: true)
        }

        textView.undoManager?.endUndoGrouping()
    }
}
