//
//  TextViewController+IndentLines.swift
//  CodeEditTextView
//
//  Created by Ludwig, Tom on 11.09.24.
//

import AppKit
import CodeEditTextView

extension TextViewController {
    /// Handles indentation and unindentation for selected lines in the text view.
    ///
    /// This function modifies the indentation of the selected lines based on the current `indentOption`.
    /// It handles both indenting (moving text to the right) and unindenting (moving text to the left), with the
    /// behavior depending on whether `inwards` is `true` or `false`. It processes the `indentOption` to apply the
    /// correct number of spaces or tabs.
    ///
    /// The function operates on **one-to-many selections**, where each selection can affect **one-to-many lines**.
    /// Each of those lines will be modified accordingly.
    ///
    /// ```
    /// +----------------------------+
    /// | Selection 1                |
    /// |                            |
    /// | +------------------------+ |
    /// | | Line 1 (Modified)      | |
    /// | +------------------------+ |
    /// | +------------------------+ |
    /// | | Line 2 (Modified)      | |
    /// | +------------------------+ |
    /// +----------------------------+
    ///
    /// +----------------------------+
    /// | Selection 2                |
    /// |                            |
    /// | +------------------------+ |
    /// | | Line 1 (Modified)      | |
    /// | +------------------------+ |
    /// | +------------------------+ |
    /// | | Line 2 (Modified)      | |
    /// | +------------------------+ |
    /// +----------------------------+
    /// ```
    ///
    /// **Selection Updates**:
    /// The method will not update the selection (and its highlighting) until all lines for the given selection
    /// have been processed. This ensures that the selection updates are only applied after all indentations
    /// are completed, preventing issues where the selection might be updated incrementally during the processing
    /// of multiple lines.
    ///
    /// - Parameter inwards: A `Bool` flag indicating whether to outdent (default is `false`).
    ///   - If `inwards` is `true`, the text will be unindented.
    ///   - If `inwards` is `false`, the text will be indented.
    ///
    /// - Note: This function assumes that the document is formatted according to the selected indentation option.
    ///   It will not indent a tab character if spaces are selected, and vice versa. Ensure that the document is
    ///   properly formatted before invoking this function.
    ///
    /// - Important: This method operates on the current selections in the `textView`. It performs a reverse iteration
    ///   over the text selections, ensuring that edits do not affect the later selections.

    public func handleIndent(inwards: Bool = false) {
        guard !cursorPositions.isEmpty else { return }

        textView.undoManager?.beginUndoGrouping()
        var selectionIndex = 0
        textView.editSelections { textView, selection in
            // get lineindex, i.e line-numbers+1
            guard let lineIndexes = getOverlappingLines(for: selection.range) else { return }

            adjustIndentation(lineIndexes: lineIndexes, inwards: inwards)

            updateSelection(
                selection: selection,
                textSelectionCount: textView.selectionManager.textSelections.count,
                inwards: inwards,
                lineCount: lineIndexes.count,
                selectionIndex: selectionIndex
            )

            selectionIndex += 1
        }
        textView.undoManager?.endUndoGrouping()
    }

    private func updateSelection(
        selection: TextSelectionManager.TextSelection,
        textSelectionCount: Int,
        inwards: Bool,
        lineCount: Int,
        selectionIndex: Int
    ) {
        let sectionModifier = calculateSelectionIndentationAdjustment(
            textSelectionCount: textSelectionCount,
            selectionIndex: selectionIndex,
            lineCount: lineCount
        )

        let charCount = configuration.behavior.indentOption.charCount

        selection.range.location += inwards ? -charCount * sectionModifier : charCount * sectionModifier
        if lineCount > 1 {
            let ammount = charCount * (lineCount - 1)
            selection.range.length += inwards ? -ammount : ammount
        }
    }

    private func calculateSelectionIndentationAdjustment(
        textSelectionCount: Int,
        selectionIndex: Int,
        lineCount: Int
    ) -> Int {
        return 1 + ((textSelectionCount - selectionIndex) - 1) * lineCount
    }

    /// This method is used to handle tabs appropriately when multiple lines are selected,
    /// allowing normal use of tabs.
    ///
    /// - Returns: A Boolean value indicating whether multiple lines are highlighted.
    func multipleLinesHighlighted() -> Bool {
        for cursorPosition in self.cursorPositions {
            if let startLineInfo = textView.layoutManager.textLineForOffset(cursorPosition.range.lowerBound),
               let endLineInfo = textView.layoutManager.textLineForOffset(cursorPosition.range.upperBound),
               startLineInfo.index != endLineInfo.index {
                return true
            }
        }
        return false
    }

    /// Find the range of lines overlapping a text range.
    ///
    /// Use this method to determine what lines to apply a text transformation on using a text selection. For instance,
    /// when indenting a selected line.
    ///
    /// Does not determine the *visible* lines, which is a very slight change from most
    /// ``CodeEditTextView/TextLayoutManager`` APIs.
    /// Given the text:
    /// ```
    /// A
    /// B
    /// ```
    /// This method will return lines `0...0` for the text range `0..<2`. The layout manager might return lines
    /// `0...1`, as the text range contains the newline, which appears *visually* in line index `1`.
    ///
    /// - Parameter range: The text range in the document to find contained lines for.
    /// - Returns: A closed range of line indexes (0-indexed) where each line is overlapping the given text range.
    func getOverlappingLines(for range: NSRange) -> ClosedRange<Int>? {
        guard let startLineInfo = textView.layoutManager.textLineForOffset(range.lowerBound) else {
            return nil
        }

        guard let endLineInfo = textView.layoutManager.textLineForOffset(range.upperBound),
              endLineInfo.index != startLineInfo.index else {
            return startLineInfo.index...startLineInfo.index
        }

        // If we've selected up to the start of a line (just over the newline character), the layout manager tells us
        // we've selected the next line. However, we aren't overlapping the *text line* with that range, so we
        // decrement it if it's not the end of the document
        var endLineIndex = endLineInfo.index
        if endLineInfo.range.lowerBound == range.upperBound
            && endLineInfo.index != textView.layoutManager.lineCount - 1 {
            endLineIndex -= 1
        }

        return startLineInfo.index...endLineIndex
    }

    private func adjustIndentation(lineIndexes: ClosedRange<Int>, inwards: Bool) {
        let indentationChars: String = configuration.behavior.indentOption.stringValue
        for lineIndex in lineIndexes {
            adjustIndentation(
                lineIndex: lineIndex,
                indentationChars: indentationChars,
                inwards: inwards
            )
        }
    }

    private func adjustIndentation(lineIndex: Int, indentationChars: String, inwards: Bool) {
        guard let lineInfo = textView.layoutManager.textLineForIndex(lineIndex) else { return }

        if inwards {
            if configuration.behavior.indentOption != .tab {
                removeLeadingSpaces(lineInfo: lineInfo, spaceCount: indentationChars.count)
            } else {
                removeLeadingTab(lineInfo: lineInfo)
            }
        } else {
            addIndentation(lineInfo: lineInfo, indentationChars: indentationChars)
        }
    }

    private func addIndentation(
        lineInfo: TextLineStorage<TextLine>.TextLinePosition,
        indentationChars: String
    ) {
        textView.replaceCharacters(
            in: NSRange(location: lineInfo.range.lowerBound, length: 0),
            with: indentationChars,
            skipUpdateSelection: true
        )
    }

    private func removeLeadingSpaces(
        lineInfo: TextLineStorage<TextLine>.TextLinePosition,
        spaceCount: Int
    ) {
        guard let lineContent = textView.textStorage.substring(from: lineInfo.range) else { return }

        let removeSpacesCount = countLeadingSpacesUpTo(line: lineContent, maxCount: spaceCount)

        guard removeSpacesCount > 0 else { return }

        textView.replaceCharacters(
            in: NSRange(location: lineInfo.range.lowerBound, length: removeSpacesCount),
            with: "",
            skipUpdateSelection: true
        )
    }

    private func removeLeadingTab(lineInfo: TextLineStorage<TextLine>.TextLinePosition) {
        guard let lineContent = textView.textStorage.substring(from: lineInfo.range) else {
            return
        }

        if lineContent.first == "\t" {
            textView.replaceCharacters(
                in: NSRange(location: lineInfo.range.lowerBound, length: 1),
                with: "",
                skipUpdateSelection: true
            )
        }
    }

    func countLeadingSpacesUpTo(line: String, maxCount: Int) -> Int {
        var count = 0
        for char in line {
            if char == " " {
                count += 1
            } else {
                break  // Stop as soon as a non-space character is encountered
            }
            // Stop early if we've counted the max number of spaces
            if count == maxCount {
                break
            }
        }

        return count
    }
}
