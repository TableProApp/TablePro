//
//  SQLIndexKeyList.swift
//  TableProPluginKit
//

import Foundation

public enum SQLIndexKeyList {
    public struct Statement: Equatable, Sendable {
        public let keyList: String
        public let keyParts: [String]
        public let predicate: String?
    }

    private static let openParen = UInt16(UnicodeScalar("(").value)
    private static let closeParen = UInt16(UnicodeScalar(")").value)
    private static let comma = UInt16(UnicodeScalar(",").value)
    private static let semicolon = UInt16(UnicodeScalar(";").value)
    private static let doubleQuote = UInt16(UnicodeScalar("\"").value)
    private static let backtick = UInt16(UnicodeScalar("`").value)
    private static let openBracket = UInt16(UnicodeScalar("[").value)
    private static let closeBracket = UInt16(UnicodeScalar("]").value)
    private static let sortOrderWords: Set<String> = ["ASC", "DESC"]

    public static func statement(_ createIndex: String, lexicalFeatures: SQLLexicalFeatures) -> Statement? {
        let lexer = SQLFeatureLexer(createIndex, features: lexicalFeatures)
        guard let open = firstOpenParen(in: lexer),
              let close = matchingCloseParen(in: lexer, openingAt: open) else { return nil }
        let keyList = text(of: lexer, from: open + 1, to: close)
        return Statement(
            keyList: keyList,
            keyParts: parts(of: keyList, lexicalFeatures: lexicalFeatures),
            predicate: predicate(in: lexer, after: close + 1)
        )
    }

    public static func parts(of keyList: String, lexicalFeatures: SQLLexicalFeatures) -> [String] {
        let lexer = SQLFeatureLexer(keyList, features: lexicalFeatures)
        var parts: [String] = []
        var start = 0
        var depth = 0
        var index = 0
        while index < lexer.count {
            if let span = lexer.span(at: index) {
                index = max(span.end, index + 1)
                continue
            }
            let unit = lexer.units[index]
            if unit == openParen {
                depth += 1
            } else if unit == closeParen {
                depth = max(0, depth - 1)
            } else if unit == comma, depth == 0 {
                parts.append(text(of: lexer, from: start, to: index))
                start = index + 1
            }
            index += 1
        }
        parts.append(text(of: lexer, from: start, to: lexer.count))
        return parts.map(trimmed).filter { !$0.isEmpty }
    }

    public static func withoutSortOrder(_ part: String, lexicalFeatures: SQLLexicalFeatures) -> String {
        let lexer = SQLFeatureLexer(part, features: lexicalFeatures)
        guard let word = lastCodeWord(in: lexer), sortOrderWords.contains(word.text.uppercased()) else { return part }
        let head = trimmed(text(of: lexer, from: 0, to: word.start))
        return head.isEmpty ? part : head
    }

    public static func unwrapped(_ part: String, lexicalFeatures: SQLLexicalFeatures) -> String? {
        let body = trimmed(part)
        let lexer = SQLFeatureLexer(body, features: lexicalFeatures)
        guard lexer.count > 2, lexer.units[0] == openParen,
              let close = matchingCloseParen(in: lexer, openingAt: 0), close == lexer.count - 1 else { return nil }
        return trimmed(text(of: lexer, from: 1, to: close))
    }

    public static func quotedIdentifier(_ part: String, lexicalFeatures: SQLLexicalFeatures) -> String? {
        let body = trimmed(part)
        let lexer = SQLFeatureLexer(body, features: lexicalFeatures)
        guard lexer.count >= 2,
              let closer = identifierCloser(for: lexer.units[0], lexicalFeatures: lexicalFeatures),
              let span = lexer.span(at: 0), span.end == lexer.count,
              lexer.units[lexer.count - 1] == closer else { return nil }
        let name = text(of: lexer, from: 1, to: lexer.count - 1)
        guard closer != closeBracket else { return name }
        let quote = String(decoding: [closer], as: UTF16.self)
        return name.replacingOccurrences(of: quote + quote, with: quote)
    }

    private static func identifierCloser(for opener: UInt16, lexicalFeatures: SQLLexicalFeatures) -> UInt16? {
        if opener == doubleQuote { return doubleQuote }
        if opener == backtick, lexicalFeatures.contains(.backtickQuotes) { return backtick }
        if opener == openBracket, lexicalFeatures.contains(.bracketQuotedIdentifiers) { return closeBracket }
        return nil
    }

    private static func firstOpenParen(in lexer: SQLFeatureLexer) -> Int? {
        var index = 0
        while index < lexer.count {
            if let span = lexer.span(at: index) {
                index = max(span.end, index + 1)
                continue
            }
            if lexer.units[index] == openParen { return index }
            index += 1
        }
        return nil
    }

    private static func matchingCloseParen(in lexer: SQLFeatureLexer, openingAt open: Int) -> Int? {
        var depth = 0
        var index = open
        while index < lexer.count {
            if let span = lexer.span(at: index) {
                index = max(span.end, index + 1)
                continue
            }
            let unit = lexer.units[index]
            if unit == openParen {
                depth += 1
            } else if unit == closeParen {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    private static func predicate(in lexer: SQLFeatureLexer, after start: Int) -> String? {
        guard let word = firstCodeWord(in: lexer, from: start), word.text.uppercased() == "WHERE" else { return nil }
        var body = trimmed(text(of: lexer, from: word.end, to: lexer.count))
        while body.utf16.last == semicolon {
            body = trimmed(String(body.dropLast()))
        }
        return body.isEmpty ? nil : body
    }

    private struct Word {
        let text: String
        let start: Int
        let end: Int
    }

    private static func firstCodeWord(in lexer: SQLFeatureLexer, from start: Int) -> Word? {
        var index = start
        while index < lexer.count {
            if let span = lexer.span(at: index) {
                guard span.kind == .comment else { return nil }
                index = max(span.end, index + 1)
                continue
            }
            let unit = lexer.units[index]
            if isBlank(unit) {
                index += 1
                continue
            }
            guard lexer.isWordUnit(unit) else { return nil }
            return word(in: lexer, startingAt: index)
        }
        return nil
    }

    private static func lastCodeWord(in lexer: SQLFeatureLexer) -> Word? {
        var last: Word?
        var depth = 0
        var index = 0
        while index < lexer.count {
            if let span = lexer.span(at: index) {
                last = nil
                index = max(span.end, index + 1)
                continue
            }
            let unit = lexer.units[index]
            if isBlank(unit) {
                index += 1
                continue
            }
            if lexer.isWordUnit(unit) {
                let found = word(in: lexer, startingAt: index)
                last = depth == 0 ? found : nil
                index = found.end
                continue
            }
            if unit == openParen { depth += 1 }
            if unit == closeParen { depth = max(0, depth - 1) }
            last = nil
            index += 1
        }
        return last
    }

    private static func word(in lexer: SQLFeatureLexer, startingAt start: Int) -> Word {
        var end = start
        while end < lexer.count, lexer.isWordUnit(lexer.units[end]) {
            end += 1
        }
        return Word(text: text(of: lexer, from: start, to: end), start: start, end: end)
    }

    private static func isBlank(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0x0C || unit == 0x0B
    }

    private static func text(of lexer: SQLFeatureLexer, from start: Int, to end: Int) -> String {
        guard start < end else { return "" }
        return String(decoding: lexer.units[start..<end], as: UTF16.self)
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
