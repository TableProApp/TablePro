//
//  MarkdownFence.swift
//  TablePro
//

import Foundation

enum MarkdownFence {
    static func wrap(_ text: String, language: String = "") -> String {
        let fence = String(repeating: "`", count: max(3, longestBacktickRun(in: text) + 1))
        return "\(fence)\(language)\n\(text)\n\(fence)"
    }

    static func longestBacktickRun(in text: String) -> Int {
        var longest = 0
        var current = 0
        for unit in text.utf16 {
            if unit == backtick {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    static func tableCell(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "" }
        // `.literal` compares code units: a `|` or line break a combining mark follows is one Character.
        return text
            .replacingOccurrences(of: "\\", with: "\\\\", options: .literal)
            .replacingOccurrences(of: "|", with: "\\|", options: .literal)
            .replacingOccurrences(of: "\r\n", with: " ", options: .literal)
            .replacingOccurrences(of: "\n", with: " ", options: .literal)
            .replacingOccurrences(of: "\r", with: " ", options: .literal)
    }

    private static let backtick = UInt16(UnicodeScalar("`").value)
}
