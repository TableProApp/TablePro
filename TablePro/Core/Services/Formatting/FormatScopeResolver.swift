//
//  FormatScopeResolver.swift
//  TablePro
//

import Foundation

internal enum FormatScopeResolver {
    struct Scope: Equatable {
        let range: NSRange
        let sql: String
        let cursorOffset: Int?
        let isSelection: Bool
    }

    static func resolve(fullText: String, selectedRange: NSRange) -> Scope {
        let nsText = fullText as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let hasSelection = selectedRange.location != NSNotFound
            && selectedRange.length > 0
            && NSIntersectionRange(selectedRange, fullRange).length == selectedRange.length

        guard hasSelection else {
            let cursor = selectedRange.location == NSNotFound
                ? 0
                : min(selectedRange.location, nsText.length)
            return Scope(range: fullRange, sql: fullText, cursorOffset: cursor, isSelection: false)
        }

        return Scope(
            range: selectedRange,
            sql: nsText.substring(with: selectedRange),
            cursorOffset: nil,
            isSelection: true
        )
    }

    static func reapplyBoundaryWhitespace(from original: String, to formatted: String) -> String {
        guard let firstNonWhitespace = original.firstIndex(where: { !$0.isWhitespace }),
              let lastNonWhitespace = original.lastIndex(where: { !$0.isWhitespace })
        else { return formatted }

        let prefix = original[original.startIndex..<firstNonWhitespace]
        let suffix = original[original.index(after: lastNonWhitespace)...]
        return prefix + formatted + suffix
    }
}
