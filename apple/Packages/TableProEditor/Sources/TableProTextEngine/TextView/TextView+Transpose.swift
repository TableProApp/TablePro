//
//  TextView+Transpose.swift
//  TableProTextEngine
//

import AppKit

extension TextView {
    // Measured against `NSTextView`: swap the characters around the caret and step past them; at a line end swap the
    // two before it and stay; with fewer than two characters to swap do nothing.
    override public func transpose(_ sender: Any?) {
        guard isEditable else { return }
        let text = textStorage.string as NSString
        var replacements: [TextReplacement] = []
        var carets: [NSRange] = []
        var claimedUpTo = -1

        for selection in selectionManager.textSelections.sorted(by: { $0.range.location < $1.range.location }) {
            let caret = selection.range.location
            guard selection.range.isEmpty, let swap = Self.transposition(at: caret, in: text) else {
                carets.append(selection.range)
                continue
            }
            guard swap.range.location >= claimedUpTo else {
                carets.append(selection.range)
                continue
            }
            claimedUpTo = swap.range.max
            replacements.append(TextReplacement(range: swap.range, string: swap.string))
            carets.append(NSRange(location: swap.caret, length: 0))
        }
        guard !replacements.isEmpty else { return }
        replaceVerbatim(replacements)
        selectionManager.setSelectedRanges(carets)
    }

    private static func transposition(
        at caret: Int,
        in text: NSString
    ) -> (range: NSRange, string: String, caret: Int)? {
        guard caret > 0, caret <= text.length else { return nil }
        let atLineEnd = caret == text.length || text.isLineBreak(at: caret)
        let second = text.caretStepRange(at: atLineEnd ? caret - 1 : caret)
        guard second.location > 0 || !atLineEnd else { return nil }
        let first = text.caretStepRange(at: atLineEnd ? second.location - 1 : caret - 1)
        let range = NSRange(location: first.location, length: second.max - first.location)
        let string = text.substring(with: second) + text.substring(with: first)
        return (range, string, atLineEnd ? caret : range.max)
    }
}
