//
//  EditorContextSelection.swift
//  TablePro
//

import Foundation

struct EditorContextSelection: Equatable, Sendable {
    let selectedRange: NSRange
    let contextClickWord: NSRange?

    var selectsOnlyClickedWord: Bool {
        guard let contextClickWord else { return false }
        return NSEqualRanges(selectedRange, contextClickWord)
    }

    var effectiveRange: NSRange {
        guard selectsOnlyClickedWord, let contextClickWord else { return selectedRange }
        return NSRange(location: contextClickWord.location, length: 0)
    }

    func selectedText(in fullText: String) -> String? {
        let range = effectiveRange
        let text = fullText as NSString
        guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= text.length else { return nil }
        return text.substring(with: range)
    }
}
