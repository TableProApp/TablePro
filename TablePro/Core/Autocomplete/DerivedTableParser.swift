//
//  DerivedTableParser.swift
//  TablePro
//
//  Parses derived-table subqueries and CTEs into their output column names so
//  autocomplete can resolve `alias.` against a subquery's SELECT list.
//

import Foundation

/// A derived table (FROM/JOIN subquery or CTE) and the column names its SELECT
/// list produces. Columns come from the query text, not the live schema.
internal struct DerivedTable: Equatable, Sendable {
    let alias: String
    let columns: [String]
}

/// Scans a SQL statement once and extracts every referenceable derived table:
/// FROM/JOIN subqueries with an alias, and CTEs defined in a WITH clause. The
/// scan is paren-, string-, and comment-aware and uses O(1) NSString access.
internal struct DerivedTableParser {
    private static let space: unichar = 0x20
    private static let tab: unichar = 0x09
    private static let newline: unichar = 0x0A
    private static let cr: unichar = 0x0D
    private static let openParen: unichar = 0x28
    private static let closeParen: unichar = 0x29
    private static let comma: unichar = 0x2C
    private static let dot: unichar = 0x2E
    private static let hyphen: unichar = 0x2D
    private static let slash: unichar = 0x2F
    private static let star: unichar = 0x2A
    private static let underscore: unichar = 0x5F
    private static let singleQuote: unichar = 0x27
    private static let doubleQuote: unichar = 0x22
    private static let backtick: unichar = 0x60
    private static let openBracket: unichar = 0x5B
    private static let closeBracket: unichar = 0x5D

    private static let clauseKeywords: Set<String> = [
        "FROM", "WHERE", "GROUP", "HAVING", "ORDER", "LIMIT", "OFFSET",
        "UNION", "INTERSECT", "EXCEPT", "WINDOW", "FETCH", "INTO", "FOR"
    ]

    private static let nonAliasKeywords: Set<String> = [
        "ON", "USING", "WHERE", "GROUP", "ORDER", "HAVING", "LIMIT", "OFFSET",
        "UNION", "INTERSECT", "EXCEPT", "JOIN", "INNER", "LEFT", "RIGHT",
        "FULL", "CROSS", "NATURAL", "AS", "SET", "RETURNING", "WINDOW"
    ]

    private static let identifierPathCharacters = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.`\"[]")
    private static let quoteCharacters = CharacterSet(charactersIn: "`\"[]")

    func parse(_ statement: String) -> [DerivedTable] {
        let ns = statement as NSString
        let length = ns.length
        var results: [DerivedTable] = []
        var seen = Set<String>()
        var i = 0
        while i < length {
            if let skipped = skipNonCode(in: ns, at: i, limit: length) {
                i = skipped
                continue
            }
            if ns.character(at: i) == Self.openParen, innerStartsWithSelect(in: ns, openIdx: i, limit: length) {
                let close = matchingParen(in: ns, openAt: i, limit: length)
                let preceding = precedingToken(in: ns, before: i)
                if let table = classify(in: ns, preceding: preceding, open: i, close: close, limit: length),
                   seen.insert(table.alias.lowercased()).inserted {
                    results.append(table)
                }
                i = close + 1
                continue
            }
            i += 1
        }
        return results
    }

    // MARK: - Classification

    private func classify(
        in ns: NSString, preceding: (text: String, start: Int),
        open: Int, close: Int, limit: Int
    ) -> DerivedTable? {
        let kind = preceding.text.uppercased()
        if kind == "AS" {
            return parseCTE(in: ns, asStart: preceding.start, subOpen: open, subClose: close)
        }
        if kind == "FROM" || kind == "JOIN" || preceding.text == "," {
            return parseDerived(in: ns, subOpen: open, subClose: close, limit: limit)
        }
        return nil
    }

    private func parseDerived(in ns: NSString, subOpen: Int, subClose: Int, limit: Int) -> DerivedTable? {
        let columns = selectListColumns(in: innerText(in: ns, open: subOpen, close: subClose))
        var cursor = firstCode(in: ns, from: subClose + 1, limit: limit)
        guard cursor < limit else { return nil }
        if let word = readWord(in: ns, at: cursor, limit: limit), word.text.uppercased() == "AS" {
            cursor = firstCode(in: ns, from: word.end, limit: limit)
        }
        guard cursor < limit, let alias = readAliasForward(in: ns, at: cursor, limit: limit) else { return nil }
        guard !Self.nonAliasKeywords.contains(alias.uppercased()) else { return nil }
        return DerivedTable(alias: alias, columns: columns)
    }

    private func parseCTE(in ns: NSString, asStart: Int, subOpen: Int, subClose: Int) -> DerivedTable? {
        var explicitColumns: [String]?
        var nameEnd = lastCodeIndex(in: ns, before: asStart)
        guard nameEnd >= 0 else { return nil }
        if ns.character(at: nameEnd) == Self.closeParen {
            let openColumn = matchingParenBackward(in: ns, closeAt: nameEnd)
            guard openColumn >= 0 else { return nil }
            explicitColumns = columnListNames(in: ns, open: openColumn, close: nameEnd)
            nameEnd = lastCodeIndex(in: ns, before: openColumn)
            guard nameEnd >= 0 else { return nil }
        }
        guard let name = readAliasBackward(in: ns, endingAt: nameEnd) else { return nil }
        let columns = explicitColumns ?? selectListColumns(in: innerText(in: ns, open: subOpen, close: subClose))
        return DerivedTable(alias: name, columns: columns)
    }

    // MARK: - SELECT list

    private func selectListColumns(in inner: String) -> [String] {
        let ns = inner as NSString
        let length = ns.length
        guard let select = topLevelKeyword(in: ns, start: 0, end: length, keywords: ["SELECT"]),
              select.word.uppercased() == "SELECT" else {
            return []
        }
        let listStart = selectListStart(in: ns, after: select.end, limit: length)
        let listEnd = topLevelKeyword(in: ns, start: listStart, end: length, keywords: Self.clauseKeywords)?.start ?? length
        guard listStart < listEnd else { return [] }

        var names: [String] = []
        var seen = Set<String>()
        for item in topLevelItems(in: ns, start: listStart, end: listEnd) {
            guard let name = deriveColumnName(item), seen.insert(name.lowercased()).inserted else { continue }
            names.append(name)
        }
        return names
    }

    /// Skip a leading `DISTINCT`/`ALL` (and a `DISTINCT ON (...)` group) so the
    /// list scan starts at the first projected expression.
    private func selectListStart(in ns: NSString, after selectEnd: Int, limit: Int) -> Int {
        var start = firstCode(in: ns, from: selectEnd, limit: limit)
        guard let modifier = readWord(in: ns, at: start, limit: limit),
              modifier.text.uppercased() == "DISTINCT" || modifier.text.uppercased() == "ALL" else {
            return start
        }
        start = firstCode(in: ns, from: modifier.end, limit: limit)
        guard let on = readWord(in: ns, at: start, limit: limit), on.text.uppercased() == "ON" else {
            return start
        }
        let parenStart = firstCode(in: ns, from: on.end, limit: limit)
        guard parenStart < limit, ns.character(at: parenStart) == Self.openParen else {
            return start
        }
        return matchingParen(in: ns, openAt: parenStart, limit: limit) + 1
    }

    private func deriveColumnName(_ rawItem: String) -> String? {
        let trimmed = rawItem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let ns = trimmed as NSString
        let length = ns.length
        if let asKeyword = topLevelKeyword(in: ns, start: 0, end: length, keywords: ["AS"]) {
            let aliasStart = firstCode(in: ns, from: asKeyword.end, limit: length)
            guard aliasStart < length else { return nil }
            return readAliasForward(in: ns, at: aliasStart, limit: length)
        }
        return plainColumnName(trimmed)
    }

    private func plainColumnName(_ item: String) -> String? {
        guard !item.contains("*"),
              item.unicodeScalars.allSatisfy(Self.identifierPathCharacters.contains) else { return nil }
        guard let last = item.split(separator: ".").last else { return nil }
        let cleaned = String(last).trimmingCharacters(in: Self.quoteCharacters)
        guard !cleaned.isEmpty, cleaned.unicodeScalars.allSatisfy(isIdentifier) else { return nil }
        return cleaned
    }

    private func isIdentifier(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
    }

    // MARK: - Token scanning

    private func topLevelKeyword(
        in ns: NSString, start: Int, end: Int, keywords: Set<String>
    ) -> (word: String, start: Int, end: Int)? {
        var i = start
        var depth = 0
        while i < end {
            if let skipped = skipNonCode(in: ns, at: i, limit: end) {
                i = skipped
                continue
            }
            let c = ns.character(at: i)
            if c == Self.openParen {
                depth += 1
                i += 1
                continue
            }
            if c == Self.closeParen {
                depth -= 1
                i += 1
                continue
            }
            if depth == 0, isWordStart(c) {
                var j = i + 1
                while j < end, isWordChar(ns.character(at: j)) { j += 1 }
                let word = ns.substring(with: NSRange(location: i, length: j - i))
                if keywords.contains(word.uppercased()) {
                    return (word, i, j)
                }
                i = j
                continue
            }
            i += 1
        }
        return nil
    }

    private func topLevelItems(in ns: NSString, start: Int, end: Int) -> [String] {
        var items: [String] = []
        var depth = 0
        var itemStart = start
        var i = start
        while i < end {
            if let skipped = skipNonCode(in: ns, at: i, limit: end) {
                i = skipped
                continue
            }
            let c = ns.character(at: i)
            if c == Self.openParen {
                depth += 1
            } else if c == Self.closeParen {
                depth -= 1
            } else if c == Self.comma, depth == 0 {
                items.append(ns.substring(with: NSRange(location: itemStart, length: i - itemStart)))
                itemStart = i + 1
            }
            i += 1
        }
        items.append(ns.substring(with: NSRange(location: itemStart, length: end - itemStart)))
        return items
    }

    private func readWord(in ns: NSString, at index: Int, limit: Int) -> (text: String, end: Int)? {
        guard index < limit, isWordStart(ns.character(at: index)) else { return nil }
        var j = index + 1
        while j < limit, isWordChar(ns.character(at: j)) { j += 1 }
        return (ns.substring(with: NSRange(location: index, length: j - index)), j)
    }

    private func readAliasForward(in ns: NSString, at index: Int, limit: Int) -> String? {
        let c = ns.character(at: index)
        if c == Self.backtick || c == Self.doubleQuote {
            let end = matchingQuote(in: ns, from: index, limit: limit, quote: c)
            guard end > index + 2 else { return nil }
            return ns.substring(with: NSRange(location: index + 1, length: end - index - 2))
        }
        if c == Self.openBracket {
            var j = index + 1
            while j < limit, ns.character(at: j) != Self.closeBracket { j += 1 }
            guard j > index + 1 else { return nil }
            return ns.substring(with: NSRange(location: index + 1, length: j - index - 1))
        }
        guard let word = readWord(in: ns, at: index, limit: limit) else { return nil }
        return word.text
    }

    private func readAliasBackward(in ns: NSString, endingAt end: Int) -> String? {
        let c = ns.character(at: end)
        if c == Self.backtick || c == Self.doubleQuote {
            var i = end - 1
            while i >= 0, ns.character(at: i) != c { i -= 1 }
            guard i >= 0, end - i - 1 > 0 else { return nil }
            return ns.substring(with: NSRange(location: i + 1, length: end - i - 1))
        }
        if c == Self.closeBracket {
            var i = end - 1
            while i >= 0, ns.character(at: i) != Self.openBracket { i -= 1 }
            guard i >= 0, end - i - 1 > 0 else { return nil }
            return ns.substring(with: NSRange(location: i + 1, length: end - i - 1))
        }
        guard isWordChar(c) else { return nil }
        var i = end
        while i >= 0, isWordChar(ns.character(at: i)) { i -= 1 }
        return ns.substring(with: NSRange(location: i + 1, length: end - i))
    }

    private func columnListNames(in ns: NSString, open: Int, close: Int) -> [String] {
        var names: [String] = []
        for entry in topLevelItems(in: ns, start: open + 1, end: close) {
            let cleaned = entry.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: Self.quoteCharacters)
            if !cleaned.isEmpty {
                names.append(cleaned)
            }
        }
        return names
    }

    // MARK: - Structural helpers

    private func innerText(in ns: NSString, open: Int, close: Int) -> String {
        guard close > open + 1 else { return "" }
        return ns.substring(with: NSRange(location: open + 1, length: close - open - 1))
    }

    private func innerStartsWithSelect(in ns: NSString, openIdx: Int, limit: Int) -> Bool {
        let start = firstCode(in: ns, from: openIdx + 1, limit: limit)
        guard let word = readWord(in: ns, at: start, limit: limit) else { return false }
        return word.text.uppercased() == "SELECT"
    }

    private func precedingToken(in ns: NSString, before index: Int) -> (text: String, start: Int) {
        var i = index - 1
        while i >= 0, isWhitespace(ns.character(at: i)) { i -= 1 }
        guard i >= 0 else { return ("", 0) }
        let c = ns.character(at: i)
        if c == Self.comma { return (",", i) }
        if c == Self.closeParen { return (")", i) }
        guard isWordChar(c) else { return (String(utf16CodeUnits: [c], count: 1), i) }
        var start = i
        while start >= 0, isWordChar(ns.character(at: start)) { start -= 1 }
        start += 1
        return (ns.substring(with: NSRange(location: start, length: i - start + 1)), start)
    }

    private func matchingParen(in ns: NSString, openAt: Int, limit: Int) -> Int {
        var depth = 0
        var i = openAt
        while i < limit {
            if let skipped = skipNonCode(in: ns, at: i, limit: limit) {
                i = skipped
                continue
            }
            let c = ns.character(at: i)
            if c == Self.openParen {
                depth += 1
            } else if c == Self.closeParen {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return limit
    }

    private func matchingParenBackward(in ns: NSString, closeAt: Int) -> Int {
        var depth = 0
        var i = closeAt
        while i >= 0 {
            let c = ns.character(at: i)
            if c == Self.closeParen {
                depth += 1
            } else if c == Self.openParen {
                depth -= 1
                if depth == 0 { return i }
            }
            i -= 1
        }
        return -1
    }

    private func firstCode(in ns: NSString, from index: Int, limit: Int) -> Int {
        var i = index
        while i < limit {
            let c = ns.character(at: i)
            if isWhitespace(c) {
                i += 1
                continue
            }
            if c == Self.hyphen, i + 1 < limit, ns.character(at: i + 1) == Self.hyphen {
                i = skipLineComment(in: ns, from: i, limit: limit)
                continue
            }
            if c == Self.slash, i + 1 < limit, ns.character(at: i + 1) == Self.star {
                i = skipBlockComment(in: ns, from: i, limit: limit)
                continue
            }
            break
        }
        return i
    }

    private func lastCodeIndex(in ns: NSString, before index: Int) -> Int {
        var i = index - 1
        while i >= 0, isWhitespace(ns.character(at: i)) { i -= 1 }
        return i
    }

    private func skipNonCode(in ns: NSString, at i: Int, limit: Int) -> Int? {
        let c = ns.character(at: i)
        if c == Self.singleQuote || c == Self.doubleQuote || c == Self.backtick {
            return matchingQuote(in: ns, from: i, limit: limit, quote: c)
        }
        if c == Self.hyphen, i + 1 < limit, ns.character(at: i + 1) == Self.hyphen {
            return skipLineComment(in: ns, from: i, limit: limit)
        }
        if c == Self.slash, i + 1 < limit, ns.character(at: i + 1) == Self.star {
            return skipBlockComment(in: ns, from: i, limit: limit)
        }
        return nil
    }

    private func matchingQuote(in ns: NSString, from index: Int, limit: Int, quote: unichar) -> Int {
        var i = index + 1
        while i < limit {
            if ns.character(at: i) == quote {
                if i + 1 < limit, ns.character(at: i + 1) == quote {
                    i += 2
                    continue
                }
                return i + 1
            }
            i += 1
        }
        return limit
    }

    private func skipLineComment(in ns: NSString, from index: Int, limit: Int) -> Int {
        var i = index + 2
        while i < limit, ns.character(at: i) != Self.newline { i += 1 }
        return i
    }

    private func skipBlockComment(in ns: NSString, from index: Int, limit: Int) -> Int {
        var i = index + 2
        while i + 1 < limit {
            if ns.character(at: i) == Self.star, ns.character(at: i + 1) == Self.slash {
                return i + 2
            }
            i += 1
        }
        return limit
    }

    private func isWhitespace(_ c: unichar) -> Bool {
        c == Self.space || c == Self.tab || c == Self.newline || c == Self.cr
    }

    private func isWordStart(_ c: unichar) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == Self.underscore
    }

    private func isWordChar(_ c: unichar) -> Bool {
        isWordStart(c) || (c >= 0x30 && c <= 0x39)
    }
}
