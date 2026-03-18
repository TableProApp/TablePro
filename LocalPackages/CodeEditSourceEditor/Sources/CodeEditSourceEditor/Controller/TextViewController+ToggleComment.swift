//
//  TextViewController+Shortcuts.swift
//  CodeEditSourceEditor
//
//  Created by Sophia Hooley on 4/21/24.
//

import CodeEditTextView
import AppKit

extension TextViewController {
    /// Method called when CMD + / key sequence is recognized.
    /// Comments or uncomments the cursor's current line(s) of code.
    public func handleCommandSlash() {
        guard let cursorPosition = cursorPositions.first else { return }
        // Set up a cache to avoid redundant computations.
        // The cache stores line information (e.g., ranges), line contents,
        // and other relevant data to improve efficiency.
        var cache = CommentCache()
        populateCommentCache(for: cursorPosition.range, using: &cache)

        // Begin an undo grouping to allow for a single undo operation for the entire comment toggle.
        textView.undoManager?.beginUndoGrouping()
        for lineInfo in cache.lineInfos {
            if let lineInfo {
                toggleComment(lineInfo: lineInfo, cache: cache)
            }
        }

        // End the undo grouping to complete the undo operation for the comment toggle.
        textView.undoManager?.endUndoGrouping()
    }

    // swiftlint:disable cyclomatic_complexity
    /// Populates the comment cache with information about the lines within a specified range,
    /// determining whether comment characters should be inserted or removed.
    /// - Parameters:
    ///   - range: The range of text to process.
    ///   - commentCache: A cache object to store comment-related data, such as line information,
    ///                   shift factors, and content.
    private func populateCommentCache(for range: NSRange, using commentCache: inout CommentCache) {
        // Determine the appropriate comment characters based on the language settings.
        if language.lineCommentString.isEmpty {
            commentCache.startCommentChars = language.rangeCommentStrings.0
            commentCache.endCommentChars = language.rangeCommentStrings.1
        } else {
            commentCache.startCommentChars = language.lineCommentString
        }

        // Return early if no comment characters are available.
        guard let startCommentChars = commentCache.startCommentChars else { return }

        // Fetch the starting line's information and content.
        guard let startLineInfo = textView.layoutManager.textLineForOffset(range.location),
              let startLineContent = textView.textStorage.substring(from: startLineInfo.range) else {
            return
        }

        // Initialize cache with the first line's information.
        commentCache.lineInfos = [startLineInfo]
        commentCache.lineStrings[startLineInfo.index] = startLineContent
        commentCache.shouldInsertCommentChars = !startLineContent
            .trimmingCharacters(in: .whitespacesAndNewlines).starts(with: startCommentChars)

        // Retrieve information for the ending line. Proceed only if the ending line
        // is different from the starting line, indicating that the user has selected more than one line.
        guard let endLineInfo = textView.layoutManager.textLineForOffset(range.upperBound),
              endLineInfo.index != startLineInfo.index else { return }

        // Check if comment characters need to be inserted for the ending line.
        if let endLineContent = textView.textStorage.substring(from: endLineInfo.range) {
            // If comment characters need to be inserted, they should be added to every line within the range.
            if !commentCache.shouldInsertCommentChars {
                commentCache.shouldInsertCommentChars = !endLineContent
                    .trimmingCharacters(in: .whitespacesAndNewlines).starts(with: startCommentChars)
            }
            commentCache.lineStrings[endLineInfo.index] = endLineContent
        }

        // Process all lines between the start and end lines.
        let intermediateLines = (startLineInfo.index + 1)..<endLineInfo.index
        for (offset, lineIndex) in intermediateLines.enumerated() {
            guard let lineInfo = textView.layoutManager.textLineForIndex(lineIndex) else { break }
            // Cache the line content here since we'll need to access it anyway
            // to append a comment at the end of the line.
            if  let lineContent = textView.textStorage.substring(from: lineInfo.range) {
                // Line content is accessed only when:
                // - A line's comment is toggled off, or
                // - Comment characters need to be appended to the end of the line.
                if language.lineCommentString.isEmpty || !commentCache.shouldInsertCommentChars {
                    commentCache.lineStrings[lineIndex] = lineContent
                }

                if !commentCache.shouldInsertCommentChars {
                    commentCache.shouldInsertCommentChars = !lineContent
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .starts(with: startCommentChars)
                }
            }

            // Cache line information and calculate the shift range factor.
            commentCache.lineInfos.append(lineInfo)
            commentCache.shiftRangeFactors[lineIndex] = calculateShiftRangeFactor(
                startCount: startCommentChars.count,
                endCount: commentCache.endCommentChars?.count,
                lineCount: offset
            )
        }

        // Cache the ending line's information and calculate its shift range factor.
        commentCache.lineInfos.append(endLineInfo)
        commentCache.shiftRangeFactors[endLineInfo.index] = calculateShiftRangeFactor(
            startCount: startCommentChars.count,
            endCount: commentCache.endCommentChars?.count,
            lineCount: intermediateLines.count
        )
    }
    // swiftlint:enable cyclomatic_complexity

    /// Calculates the shift range factor based on the counts of start and
    /// end comment characters and the number of intermediate lines.
    ///
    /// - Parameters:
    ///   - startCount: The number of characters in the start comment.
    ///   - endCount: An optional number of characters in the end comment. If `nil`, it is treated as 0.
    ///   - lineCount: The number of intermediate lines between the start and end comments.
    ///
    /// - Returns: The computed shift range factor as an `Int`.
    private func calculateShiftRangeFactor(startCount: Int, endCount: Int?, lineCount: Int) -> Int {
        let effectiveEndCount = endCount ?? 0
        return (startCount + effectiveEndCount) * (lineCount + 1)
    }
    /// Toggles the presence of comment characters at the beginning and/or end
    /// - Parameters:
    ///   - lineInfo: Contains information about the specific line, including its position and range.
    ///   - cache: A cache holding comment-related data such as the comment characters and line content.
    private func toggleComment(lineInfo: TextLineStorage<TextLine>.TextLinePosition, cache: borrowing CommentCache) {
        if cache.endCommentChars != nil {
            toggleCommentAtEndOfLine(lineInfo: lineInfo, cache: cache)
            toggleCommentAtBeginningOfLine(lineInfo: lineInfo, cache: cache)
        } else {
            toggleCommentAtBeginningOfLine(lineInfo: lineInfo, cache: cache)
        }
    }

    /// Toggles the presence of comment characters at the beginning of a line in the text view.
    /// - Parameters:
    ///   - lineInfo: Contains information about the specific line, including its position and range.
    ///   - cache: A cache holding comment-related data such as the comment characters and line content.
    private func toggleCommentAtBeginningOfLine(
        lineInfo: TextLineStorage<TextLine>.TextLinePosition,
        cache: borrowing CommentCache
    ) {
        // Ensure there are comment characters to toggle.
        guard let startCommentChars = cache.startCommentChars else { return }

        // Calculate the range shift based on cached factors, defaulting to 0 if unavailable.
        let rangeShift = cache.shiftRangeFactors[lineInfo.index] ?? 0

        // If we need to insert comment characters at the beginning of the line.
        if cache.shouldInsertCommentChars {
            guard let adjustedRange = lineInfo.range.shifted(by: rangeShift) else { return }
            textView.replaceCharacters(
                in: NSRange(location: adjustedRange.location, length: 0),
                with: startCommentChars
            )
            return
        }

        // If we need to remove comment characters from the beginning of the line.
        guard let adjustedRange = lineInfo.range.shifted(by: -rangeShift) else { return }

        // Retrieve the current line's string content from the cache or the text view's storage.
        guard let lineContent =
                cache.lineStrings[lineInfo.index] ?? textView.textStorage.substring(from: adjustedRange) else { return }

        // Find the index of the first non-whitespace character.
        let firstNonWhitespaceIndex = lineContent.firstIndex(where: { !$0.isWhitespace }) ?? lineContent.startIndex
        let leadingWhitespaceCount = lineContent.distance(from: lineContent.startIndex, to: firstNonWhitespaceIndex)

        // Remove the comment characters from the beginning of the line.
        textView.replaceCharacters(
            in: NSRange(location: adjustedRange.location + leadingWhitespaceCount, length: startCommentChars.count),
            with: ""
        )
    }

    /// Toggles the presence of comment characters at the end of a line in the text view.
    /// - Parameters:
    ///   - lineInfo: Contains information about the specific line, including its position and range.
    ///   - cache: A cache holding comment-related data such as the comment characters and line content.
    private func toggleCommentAtEndOfLine(
        lineInfo: TextLineStorage<TextLine>.TextLinePosition,
        cache: borrowing CommentCache
    ) {
        // Ensure there are comment characters to toggle and the line is not empty.
        guard let endingCommentChars = cache.endCommentChars else { return }
        guard !lineInfo.range.isEmpty else { return }

        // Calculate the range shift based on cached factors, defaulting to 0 if unavailable.
        let rangeShift = cache.shiftRangeFactors[lineInfo.index] ?? 0

        // Shift the line range by `rangeShift` if inserting comment characters, or by `-rangeShift` if removing them.
        guard let adjustedRange = lineInfo.range.shifted(by: cache.shouldInsertCommentChars ? rangeShift : -rangeShift)
        else { return }

        // Retrieve the current line's string content from the cache or the text view's storage.
        guard let lineContent =
                cache.lineStrings[lineInfo.index] ?? textView.textStorage.substring(from: adjustedRange) else { return }

        var endIndex = adjustedRange.upperBound

        // If the last character is a newline, adjust the insertion point to before the newline.
        if lineContent.last?.isNewline ?? false {
            endIndex -= 1
        }

        if cache.shouldInsertCommentChars {
            // Insert the comment characters at the calculated position.
            textView.replaceCharacters(in: NSRange(location: endIndex, length: 0), with: endingCommentChars)
        } else {
            // Remove the comment characters if they exist at the end of the line.
            let commentRange = NSRange(
                location: endIndex - endingCommentChars.count,
                length: endingCommentChars.count
            )
            textView.replaceCharacters(in: commentRange, with: "")
        }
    }
}
