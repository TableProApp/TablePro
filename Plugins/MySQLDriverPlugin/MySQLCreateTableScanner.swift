//
//  MySQLCreateTableScanner.swift
//  MySQLDriverPlugin
//

import Foundation

internal enum MySQLCreateTableScanner {
    /// Each column's `DEFAULT` operand as `SHOW CREATE TABLE` spells it, keyed by column name, or nil
    /// when the statement does not create a table. A column with no `DEFAULT` clause is absent.
    ///
    /// Read one definition per line, because OceanBase prints a `SET` or `ENUM` member list with its
    /// quotes unbalanced (`set('a','b'c')`), and a quote-aware split would run that column into the
    /// next. A quoted column name is the one thing every server quotes correctly, and it may hold a
    /// line break, so a line that opens a name without closing it runs on into the next: read on its
    /// own, the rest of that name would reach another column as its default.
    static func columnDefaultClauses(fromCreateTable sql: String) -> [String: String]? {
        let lines = sql.split(separator: "\n", omittingEmptySubsequences: false)
        guard let header = lines.first, declaresTable(header) else { return nil }
        var clauses: [String: String] = [:]
        var first = lines.index(after: lines.startIndex)
        while first < lines.endIndex {
            var last = first
            while last + 1 < lines.endIndex,
                  opensUnclosedName(sql[lines[first].startIndex..<lines[last].endIndex]) {
                last += 1
            }
            var definition = sql[lines[first].startIndex..<lines[last].endIndex].drop(while: \.isWhitespace)
            first = last + 1
            guard let name = columnName(consumingFrom: &definition),
                  let operand = defaultOperand(in: withoutTrailingSeparator(definition))
            else { continue }
            clauses[name] = operand
        }
        return clauses
    }

    static func firstGroup(in text: Substring) -> Substring? {
        var depth = 0
        var start: Substring.Index?
        for (index, mark) in structuralMarks(in: text) {
            switch mark {
            case "(":
                if depth == 0 { start = text.index(after: index) }
                depth += 1
            case ")":
                guard depth > 0 else { return nil }
                depth -= 1
                if depth == 0, let start { return text[start..<index] }
            default:
                continue
            }
        }
        return nil
    }

    static func topLevelElements(of body: Substring) -> [Substring] {
        var elements: [Substring] = []
        var depth = 0
        var elementStart = body.startIndex
        for (index, mark) in structuralMarks(in: body) {
            switch mark {
            case "(":
                depth += 1
            case ")":
                depth -= 1
            default:
                guard depth == 0 else { continue }
                elements.append(body[elementStart..<index])
                elementStart = body.index(after: index)
            }
        }
        elements.append(body[elementStart...])
        return elements
    }

    static func consume(_ keyword: String, from rest: inout Substring) -> Bool {
        let trimmed = rest.drop(while: \.isWhitespace)
        guard trimmed.prefix(keyword.count).uppercased() == keyword else { return false }
        let remainder = trimmed.dropFirst(keyword.count)
        guard let next = remainder.first, next.isWhitespace || next == "`" || next == "(" else { return false }
        rest = remainder
        return true
    }

    static func consumeBacktickName(from rest: inout Substring) -> String? {
        consumeQuotedName(from: &rest, quote: "`")
    }

    static func consumeQuotedName(from rest: inout Substring, quote: Character) -> String? {
        var text = rest.drop(while: \.isWhitespace)
        guard text.first == quote else { return nil }
        text = text.dropFirst()
        var name = ""
        while let character = text.first {
            text = text.dropFirst()
            if character == quote {
                guard text.first == quote else {
                    rest = text
                    return name
                }
                text = text.dropFirst()
            }
            name.append(character)
        }
        return nil
    }

    static func topLevelTokens(of text: Substring) -> [Substring] {
        var tokens: [Substring] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard !text[index].isWhitespace else {
                index = text.index(after: index)
                continue
            }
            let start = index
            while index < text.endIndex, !text[index].isWhitespace {
                index = endOfUnit(in: text, from: index)
            }
            tokens.append(text[start..<index])
        }
        return tokens
    }

    static func endOfQuoted(in text: Substring, from start: Substring.Index) -> Substring.Index {
        let quote = text[start]
        var index = text.index(after: start)
        while index < text.endIndex {
            let character = text[index]
            if character == "\\", quote != "`" {
                index = text.index(after: index)
                guard index < text.endIndex else { return text.endIndex }
                index = text.index(after: index)
                continue
            }
            index = text.index(after: index)
            guard character == quote else { continue }
            guard index < text.endIndex, text[index] == quote else { return index }
            index = text.index(after: index)
        }
        return text.endIndex
    }

    private static func endOfUnit(in text: Substring, from index: Substring.Index) -> Substring.Index {
        switch text[index] {
        case "'", "\"", "`":
            return endOfQuoted(in: text, from: index)
        case "(":
            return endOfGroup(in: text, from: index)
        default:
            return text.index(after: index)
        }
    }

    private static func endOfGroup(in text: Substring, from start: Substring.Index) -> Substring.Index {
        var depth = 0
        var index = start
        while index < text.endIndex {
            switch text[index] {
            case "'", "\"", "`":
                index = endOfQuoted(in: text, from: index)
                continue
            case "(":
                depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return text.index(after: index) }
            default:
                break
            }
            index = text.index(after: index)
        }
        return text.endIndex
    }

    private static func structuralMarks(in text: Substring) -> [(index: Substring.Index, mark: Character)] {
        var marks: [(index: Substring.Index, mark: Character)] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            switch character {
            case "'", "\"", "`":
                index = endOfQuoted(in: text, from: index)
                continue
            case "(", ")", ",":
                marks.append((index, character))
            default:
                break
            }
            index = text.index(after: index)
        }
        return marks
    }

    private static func declaresTable(_ header: Substring) -> Bool {
        let words = header.prefix { $0 != "`" && $0 != "\"" && $0 != "(" }
            .split(whereSeparator: \.isWhitespace)
            .map { $0.uppercased() }
        guard words.first == "CREATE", let tableIndex = words.firstIndex(of: "TABLE") else { return false }
        return !words[..<tableIndex].contains("VIEW")
    }

    private static func columnName(consumingFrom definition: inout Substring) -> String? {
        if let quote = definition.first, quote == "`" || quote == "\"" {
            return consumeQuotedName(from: &definition, quote: quote)
        }
        guard let first = definition.first, first.isLetter || first.isNumber || first == "_" || first == "$" else {
            return nil
        }
        let name = definition.prefix { !$0.isWhitespace }
        definition = definition.dropFirst(name.count)
        return String(name)
    }

    private static func opensUnclosedName(_ text: Substring) -> Bool {
        var definition = text.drop(while: \.isWhitespace)
        guard let quote = definition.first, quote == "`" || quote == "\"" else { return false }
        return consumeQuotedName(from: &definition, quote: quote) == nil
    }

    private static func withoutTrailingSeparator(_ definition: Substring) -> Substring {
        var trimmed = definition
        while let last = trimmed.last, last.isWhitespace {
            trimmed = trimmed.dropLast()
        }
        return trimmed.last == "," ? trimmed.dropLast() : trimmed
    }

    private static func defaultOperand(in definition: Substring) -> String? {
        let tokens = topLevelTokens(of: definition)
        for (index, token) in tokens.enumerated() {
            let upper = token.uppercased()
            if upper == "DEFAULT" {
                return tokens.indices.contains(index + 1) ? String(tokens[index + 1]) : nil
            }
            if upper.hasPrefix("DEFAULT("), token.count > "DEFAULT".count {
                return String(token.dropFirst("DEFAULT".count))
            }
        }
        return nil
    }
}
