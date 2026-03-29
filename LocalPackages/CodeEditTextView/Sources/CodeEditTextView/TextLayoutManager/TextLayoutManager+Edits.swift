//
//  TextLayoutManager+Edits.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 9/3/23.
//

import AppKit

// MARK: - Edits

extension TextLayoutManager: NSTextStorageDelegate {
    /// Receives edit notifications from the text storage and updates internal data structures to stay in sync with
    /// text content.
    ///
    /// If the changes are only attribute changes, this method invalidates layout for the edited range and returns.
    ///
    /// Otherwise, any lines that were removed or replaced by the edit are first removed from the text line layout
    /// storage. Then, any new lines are inserted into the same storage.
    ///
    /// For instance, if inserting a newline this method will:
    /// - Remove no lines (none were replaced)
    /// - Update the current line's range to contain the newline character.
    /// - Insert a new line after the current line.
    ///
    /// If a selection containing a newline is deleted and replaced with two more newlines this method will:
    /// - Delete the original line.
    /// - Insert two lines.
    ///
    /// - Note: This method *does not* cause a layout calculation. If a method is finding `NaN` values for line
    ///         fragments, ensure `layout` or `ensureLayoutUntil` are called on the subject ranges.
    public func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else {
            if editedMask.contains(.editedAttributes) && delta == 0 {
                invalidateLayoutForRange(editedRange)
            }
            return
        }

        let insertedStringRange = NSRange(location: editedRange.location, length: editedRange.length - delta)
        removeLayoutLinesIn(range: insertedStringRange)
        insertNewLines(for: editedRange)

        attachments.textUpdated(atOffset: editedRange.location, delta: delta)

        invalidateLayoutForRange(insertedStringRange)
    }

    /// Removes all lines in the range, as if they were deleted. This is a setup for inserting the lines back in on an
    /// edit.
    /// - Parameter range: The range that was deleted.
    private func removeLayoutLinesIn(range: NSRange) {
        // Loop through each line being replaced in reverse, updating and removing where necessary.
        for linePosition in lineStorage.linesInRange(range).reversed() {
            // Two cases: Updated line, deleted line entirely
            guard let intersection = linePosition.range.intersection(range), !intersection.isEmpty else { continue }
            if intersection == linePosition.range && linePosition.range.max != lineStorage.length {
                // Delete line
                lineStorage.delete(lineAt: linePosition.range.location)
            } else if intersection.max == linePosition.range.max,
                      let nextLine = lineStorage.getLine(atOffset: linePosition.range.max) {
                // Need to merge line with one after it after updating this line to remove the end of the line
                lineStorage.delete(lineAt: nextLine.range.location)
                let delta = -intersection.length + nextLine.range.length
                if delta != 0 {
                    lineStorage.update(atOffset: linePosition.range.location, delta: delta, deltaHeight: 0)
                }
            } else {
                lineStorage.update(atOffset: linePosition.range.location, delta: -intersection.length, deltaHeight: 0)
            }
        }
    }

    /// Inserts any newly inserted lines into the line layout storage. Exits early if the range is empty.
    /// - Parameter range: The range of the string that was inserted into the text storage.
    private func insertNewLines(for range: NSRange) {
        guard !range.isEmpty, let string = textStorage?.substring(from: range) as? NSString else { return }
        // Loop through each line being inserted, inserting & splitting where necessary
        var index = 0
        while let nextLine = string.getNextLine(startingAt: index) {
            let lineRange = NSRange(start: index, end: nextLine.max)
            applyLineInsert(string.substring(with: lineRange) as NSString, at: range.location + index)
            index = nextLine.max
        }

        if index < string.length {
            // Get the last line.
            applyLineInsert(string.substring(from: index) as NSString, at: range.location + index)
        }
    }

    /// Applies a line insert to the internal line storage tree.
    /// - Parameters:
    ///   - insertedString: The string being inserted.
    ///   - location: The location the string is being inserted into.
    private func applyLineInsert(_ insertedString: NSString, at location: Int) {
        if LineEnding(line: insertedString as String) != nil {
            if location == lineStorage.length {
                // Insert a new line at the end of the document, need to insert a new line 'cause there's nothing to
                // split. Also, append the new text to the last line.
                lineStorage.update(atOffset: location, delta: insertedString.length, deltaHeight: 0.0)
                lineStorage.insert(
                    line: TextLine(),
                    atOffset: location + insertedString.length,
                    length: 0,
                    height: estimateLineHeight()
                )
            } else {
                // Need to split the line inserting into and create a new line with the split section of the line
                guard let linePosition = lineStorage.getLine(atOffset: location) else { return }
                let splitLocation = location + insertedString.length
                let splitLength = linePosition.range.max - location
                let lineDelta = insertedString.length - splitLength // The difference in the line being edited
                if lineDelta != 0 {
                    lineStorage.update(atOffset: location, delta: lineDelta, deltaHeight: 0.0)
                }

                lineStorage.insert(
                    line: TextLine(),
                    atOffset: splitLocation,
                    length: splitLength,
                    height: estimateLineHeight()
                )
            }
        } else {
            lineStorage.update(atOffset: location, delta: insertedString.length, deltaHeight: 0.0)
        }
    }
}
