//
//  TextViewController+EmphasizeBracket.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 4/26/23.
//

import AppKit
import CodeEditTextView

extension TextViewController {
    /// Emphasizes bracket pairs using the current selection.
    internal func emphasizeSelectionPairs() {
        guard let bracketPairEmphasis = configuration.appearance.bracketPairEmphasis else { return }
        textView.emphasisManager?.removeEmphases(for: EmphasisGroup.brackets)
        for range in textView.selectionManager.textSelections.map({ $0.range }) {
            if range.isEmpty,
               range.location > 0, // Range is not the beginning of the document
               let precedingCharacter = textView.textStorage.substring(
                from: NSRange(location: range.location - 1, length: 1) // The preceding character exists
               ) {
                for pair in BracketPairs.emphasisValues {
                    if precedingCharacter == pair.0 {
                        // Walk forwards
                        emphasizeForwards(pair, range: range, emphasisType: bracketPairEmphasis)
                    } else if precedingCharacter == pair.1 && range.location - 1 > 0 {
                        // Walk backwards
                        emphasizeBackwards(pair, range: range, emphasisType: bracketPairEmphasis)
                    }
                }
            }
        }
    }

    private func emphasizeForwards(_ pair: (String, String), range: NSRange, emphasisType: BracketPairEmphasis) {
        if let characterIndex = findClosingPair(
            pair.0,
            pair.1,
            from: range.location,
            limit: min((textView.visibleTextRange ?? .zero).max + 4096, textView.documentRange.max),
            reverse: false
        ) {
            emphasizeCharacter(characterIndex)
            if emphasisType.emphasizesSourceBracket {
                emphasizeCharacter(range.location - 1)
            }
        }
    }

    private func emphasizeBackwards(_ pair: (String, String), range: NSRange, emphasisType: BracketPairEmphasis) {
        if let characterIndex = findClosingPair(
            pair.1,
            pair.0,
            from: range.location - 1,
            limit: max((textView.visibleTextRange?.location ?? 0) - 4096, textView.documentRange.location),
            reverse: true
        ) {
            emphasizeCharacter(characterIndex)
            if emphasisType.emphasizesSourceBracket {
                emphasizeCharacter(range.location - 1)
            }
        }
    }

    /// # Dev Note
    /// It's interesting to note that this problem could trivially be turned into a monoid, and the locations of each
    /// pair start/end location determined when the view is loaded. It could then be parallelized for initial speed
    /// and this lookup would be much faster.

    /// Finds a closing character given a pair of characters, ignores pairs inside the given pair.
    ///
    /// ```pseudocode
    /// { -- Start
    ///   {
    ///   } -- A naive algorithm may find this character as the closing pair, which would be incorrect.
    /// } -- Found
    /// ```
    ///
    /// - Parameters:
    ///   - open: The opening pair to look for.
    ///   - close: The closing pair to look for.
    ///   - from: The index to start from. This should not include the start character. Eg given `"{ }"` looking forward
    ///           the index should be `1`
    ///   - limit: A limiting index to stop at. When `reverse` is `true`, this is the minimum index. When `false` this
    ///            is the maximum index.
    ///   - reverse: Set to `true` to walk backwards from `from`.
    /// - Returns: The index of the found closing pair, if any.
    internal func findClosingPair(_ close: String, _ open: String, from: Int, limit: Int, reverse: Bool) -> Int? {
        // Walk the text, counting each close. When we find an open that makes closeCount < 0, return that index.
        var options: NSString.EnumerationOptions = .byCaretPositions
        if reverse {
            options = options.union(.reverse)
        }
        var closeCount = 0
        var index: Int?
        textView.textStorage.mutableString.enumerateSubstrings(
            in: reverse ?
                NSRange(location: limit, length: from - limit) :
                NSRange(location: from, length: limit - from),
            options: options,
            using: { substring, range, _, stop in
                if substring == close {
                    closeCount += 1
                } else if substring == open {
                    closeCount -= 1
                }

                if closeCount < 0 {
                    index = range.location
                    stop.pointee = true
                }
            }
        )
        return index
    }

    /// Adds a temporary emphasis effect to the character at the given location.
    /// - Parameters:
    ///   - location: The location of the character to emphasize
    ///   - scrollToRange: Set to true to scroll to the given range when emphasizing. Defaults to `false`.
    private func emphasizeCharacter(_ location: Int, scrollToRange: Bool = false) {
        guard let bracketPairEmphasis = configuration.appearance.bracketPairEmphasis else {
            return
        }

        let range = NSRange(location: location, length: 1)

        switch bracketPairEmphasis {
        case .flash:
            textView.emphasisManager?.addEmphasis(
                Emphasis(
                    range: range,
                    style: .standard,
                    flash: true,
                    inactive: false
                ),
                for: EmphasisGroup.brackets
            )
        case .bordered(let borderColor):
            textView.emphasisManager?.addEmphasis(
                Emphasis(
                    range: range,
                    style: .outline(color: borderColor),
                    flash: false,
                    inactive: false
                ),
                for: EmphasisGroup.brackets
            )
        case .underline(let underlineColor):
            textView.emphasisManager?.addEmphasis(
                Emphasis(
                    range: range,
                    style: .underline(color: underlineColor),
                    flash: false,
                    inactive: false
                ),
                for: EmphasisGroup.brackets
            )
        }
    }
}
