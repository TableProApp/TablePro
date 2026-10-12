//
//  CompareRowFilter.swift
//  TablePro
//

import Foundation

internal enum CompareRowFilter {
    internal static func normalized(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    internal static func validationError(for text: String) -> String? {
        guard let filter = normalized(text) else { return nil }
        guard !filter.contains(";") else {
            return String(localized: "A filter is a single condition and cannot contain a semicolon.")
        }
        /// `SQLBoundaryValidator` anchors `--` to the start or to whitespace, and the filter is
        /// spliced into a single-line statement, so `id = 1--x` would comment out the ORDER BY and
        /// the row limit that follow it. `#` is MySQL's line comment and does the same.
        guard !filter.contains("--"), !filter.contains("#"),
              SQLBoundaryValidator.isRawFilterConditionSafe(filter) else {
            return String(localized: "A filter cannot contain a comment.")
        }
        /// Both readings of a backslash have to agree. MySQL, MariaDB and ClickHouse treat it as an
        /// escape inside a string literal and PostgreSQL does not, so a filter that is balanced
        /// under one reading and not the other closes the parenthesis this condition is wrapped in
        /// on one engine and not on the other.
        guard isBalanced(filter, backslashEscapes: true), isBalanced(filter, backslashEscapes: false) else {
            return String(localized: "A quote or parenthesis in this filter is not closed.")
        }
        return nil
    }

    internal static func condition(for filter: String) -> String {
        "(\(filter))"
    }

    private static func isBalanced(_ text: String, backslashEscapes: Bool) -> Bool {
        var depth = 0
        var closingQuote: Character?
        var characters = Array(text).makeIterator()
        var pending: Character?

        while let character = pending ?? characters.next() {
            pending = nil
            if let quote = closingQuote {
                if backslashEscapes, character == "\\", quote != "]" {
                    _ = characters.next()
                    continue
                }
                guard character == quote else { continue }
                let next = characters.next()
                if next == quote, quote != "]" { continue }
                closingQuote = nil
                pending = next
                continue
            }
            switch character {
            case "'", "\"", "`":
                closingQuote = character
            case "[":
                closingQuote = "]"
            case "(":
                depth += 1
            case ")":
                depth -= 1
                guard depth >= 0 else { return false }
            default:
                break
            }
        }
        return depth == 0 && closingQuote == nil
    }
}
