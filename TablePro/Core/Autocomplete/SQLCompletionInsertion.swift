//
//  SQLCompletionInsertion.swift
//  TablePro
//
//  Accept-time resolution of what text a completion inserts and where the
//  caret lands, in UTF-16 units relative to the insertion start. Favorites
//  honor the SQLSnippetMarker cursor token, function completions ending in
//  "()" park the caret between the parentheses, everything else places the
//  caret after the inserted text.
//

import Foundation

enum SQLCompletionInsertion {
    struct Resolution {
        let text: String
        let cursorOffset: Int
    }

    static func resolve(for item: SQLCompletionItem) -> Resolution {
        if item.kind == .favorite, let expansion = SQLSnippetMarker.expand(item.insertText) {
            return Resolution(text: expansion.text, cursorOffset: expansion.cursorOffset)
        }
        let length = (item.insertText as NSString).length
        let cursorOffset = item.insertText.hasSuffix("()") ? length - 1 : length
        return Resolution(text: item.insertText, cursorOffset: cursorOffset)
    }
}
