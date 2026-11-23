//
//  FindPanelViewModel+Find.swift
//  TableProEditorKit
//
//  Created by Khan Winter on 4/18/25.
//

import Foundation

extension FindPanelViewModel {
    // MARK: - Find

    /// Performs a find operation on the find target and updates both the ``findMatches`` array and the emphasis
    /// manager's emphases.
    func find() {
        staleMatchesCaret = nil
        findMatches = searchResults().map(\.range)

        // Find the nearest match to the current cursor position
        currentFindMatchIndex = getNearestEmphasisIndex(matchRanges: findMatches, caret: caretLocation)

        // Only add emphasis layers if the find panel is focused
        if isFocused {
            addMatchEmphases(flashCurrent: false)
        }
    }

    /// Searches the document again after it was replaced wholesale. Replacing the text posts no change notification,
    /// so the stored matches would otherwise point into text that is gone.
    func documentDidReplace() {
        clearMatchEmphases()
        if defersSearch, !findText.isEmpty {
            staleMatchesCaret = StaleMatchesCaret(location: caretLocation)
            return
        }
        staleMatchesCaret = nil
        findMatches = searchResults().map(\.range)
        currentFindMatchIndex = getNearestEmphasisIndex(matchRanges: findMatches, caret: caretLocation)
    }

    func findAfterEdit() {
        if defersSearch {
            staleMatchesCaret = StaleMatchesCaret(location: caretLocation)
        } else {
            find()
        }
    }

    func refreshMatchesIfStale() {
        guard let stale = staleMatchesCaret else { return }
        staleMatchesCaret = nil
        findMatches = searchResults().map(\.range)
        currentFindMatchIndex = getNearestEmphasisIndex(matchRanges: findMatches, caret: stale.location)
    }

    private var defersSearch: Bool {
        !isShowingFindPanel && !isFocused
    }

    private var caretLocation: Int? {
        target?.cursorPositions.first?.range.location
    }

    /// The find text's matches in the document as it is now. Empty when there is no target, no find text, or a
    /// regular expression that does not compile.
    func searchResults() -> [NSTextCheckingResult] {
        guard let target, let regex = makeRegex() else { return [] }
        return regex.matches(in: target.textView.string, range: target.textView.documentRange)
            .filter { !$0.range.isEmpty }
    }

    private func makeRegex() -> NSRegularExpression? {
        guard !findText.isEmpty else { return nil }

        // Set case sensitivity based on matchCase property
        var findOptions: NSRegularExpression.Options = matchCase ? [] : [.caseInsensitive]

        // Add multiline options for regular expressions
        if findMethod == .regularExpression {
            findOptions.insert(.dotMatchesLineSeparators)
            findOptions.insert(.anchorsMatchLines)
        }

        let pattern: String

        switch findMethod {
        case .contains:
            // Simple substring match, escape special characters
            pattern = NSRegularExpression.escapedPattern(for: findText)

        case .matchesWord:
            // Match whole words only using word boundaries
            pattern = "\\b" + NSRegularExpression.escapedPattern(for: findText) + "\\b"

        case .startsWith:
            // Match at the start of a line or after a word boundary
            pattern = "(?:^|\\b)" + NSRegularExpression.escapedPattern(for: findText)

        case .endsWith:
            // Match at the end of a line or before a word boundary
            pattern = NSRegularExpression.escapedPattern(for: findText) + "(?:$|\\b)"

        case .regularExpression:
            // Use the pattern directly without additional escaping
            pattern = findText
        }

        return try? NSRegularExpression(pattern: pattern, options: findOptions)
    }

    // MARK: - Get Nearest Emphasis Index

    private func getNearestEmphasisIndex(matchRanges: [NSRange], caret: Int?) -> Int? {
        // order the array as follows
        // Found: 1 -> 2 -> 3 -> 4
        // Cursor:       |
        // Result: 3 -> 4 -> 1 -> 2
        guard let start = caret else { return nil }

        var left = 0
        var right = matchRanges.count - 1
        var bestIndex = -1
        var bestDiff = Int.max  // Stores the closest difference

        while left <= right {
            let mid = left + (right - left) / 2
            let midStart = matchRanges[mid].location
            let diff = abs(midStart - start)

            // If it's an exact match, return immediately
            if diff == 0 {
                return mid
            }

            // If this is the closest so far, update the best index
            if diff < bestDiff {
                bestDiff = diff
                bestIndex = mid
            }

            // Move left or right based on the cursor position
            if midStart < start {
                left = mid + 1
            } else {
                right = mid - 1
            }
        }

        return bestIndex >= 0 ? bestIndex : nil
    }
}
