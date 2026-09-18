//
//  SQLiteSQLScanner.swift
//  TableProPluginKit
//

import Foundation

/// Walks a statement one character at a time, reporting whether each one sits inside a string
/// literal, a quoted identifier or a comment.
///
/// Every scan of stored SQLite DDL needs the same answer, so they share one implementation rather
/// than several that drift. Splitting a `CREATE TABLE` on its top-level commas and finding the
/// column list's parentheses both depend on it.
internal struct SQLiteSQLScanner {
    private let text: String
    private var index: String.Index
    private var quote: Character?
    private var comment: Comment?

    private enum Comment { case line, block }

    internal var isInsideLiteral: Bool { quote != nil || comment != nil }

    internal init(_ text: String, from start: String.Index? = nil) {
        self.text = text
        self.index = start ?? text.startIndex
    }

    internal mutating func next() -> String.Index? {
        guard index < text.endIndex else { return nil }
        let current = index
        let character = text[current]
        index = text.index(after: current)

        switch comment {
        case .line:
            if character == "\n" { comment = nil }
            return current
        case .block:
            if character == "*", index < text.endIndex, text[index] == "/" {
                comment = nil
                index = text.index(after: index)
            }
            return current
        case nil:
            break
        }

        if let open = quote {
            if character == open {
                /// A doubled quote escapes itself, so it closes nothing.
                if index < text.endIndex, text[index] == open, open != "]" {
                    index = text.index(after: index)
                } else {
                    quote = nil
                    /// The closing character is part of the literal, not the text around it.
                    return current
                }
            }
            return current
        }

        switch character {
        case "'", "\"", "`":
            quote = character
        case "[":
            quote = "]"
        case "-" where index < text.endIndex && text[index] == "-":
            comment = .line
        case "/" where index < text.endIndex && text[index] == "*":
            comment = .block
        default:
            break
        }
        return current
    }
}

/// One lexical unit of stored SQLite DDL, with the span it occupies in the source.
///
/// The span is the point: rewriting one clause out of a column definition has to cut exactly the
/// characters that clause covers and leave every other byte the user wrote untouched.
internal struct SQLiteToken: Equatable {
    /// The token's value with any quoting removed, so `"my col"` and `[my col]` both read as
    /// `my col`. Punctuation is itself.
    internal let text: String
    internal let range: Range<String.Index>
    internal let isQuoted: Bool
    internal let isStringLiteral: Bool

    /// The token as a keyword comparison wants it. Empty for anything quoted, which can never be a
    /// keyword however it is spelled: a column actually named `"references"` is not the clause.
    internal var keyword: String { isQuoted || isStringLiteral ? "" : text.uppercased() }

    internal var isPunctuation: Bool { text.count == 1 && SQLiteTokenizer.punctuation.contains(text) }
}

/// Splits stored SQLite DDL into identifiers, keywords, literals and punctuation.
///
/// Deliberately not a parser. It knows only what SQLite's own lexer must agree on: where a quoted
/// identifier ends, that a doubled quote escapes itself, and that a comment is not code. Everything
/// that reads structure out of the result walks these tokens, so the word `REFERENCES` inside a
/// `CHECK` expression's string literal cannot be mistaken for a foreign key clause.
internal enum SQLiteTokenizer {
    internal static let punctuation: Set<Character> = ["(", ")", ",", ";", ".", "+", "*", "/", "%", "<", ">", "=", "!", "|", "&", "~"]

    internal static func tokenize(_ sql: String) -> [SQLiteToken] {
        var tokens: [SQLiteToken] = []
        var index = sql.startIndex

        while index < sql.endIndex {
            let character = sql[index]

            if character.isWhitespace {
                index = sql.index(after: index)
                continue
            }
            if character == "-", let next = sql.index(index, offsetBy: 1, limitedBy: sql.endIndex),
               next < sql.endIndex, sql[next] == "-" {
                index = sql[index...].firstIndex(of: "\n").map { sql.index(after: $0) } ?? sql.endIndex
                continue
            }
            if character == "/", let next = sql.index(index, offsetBy: 1, limitedBy: sql.endIndex),
               next < sql.endIndex, sql[next] == "*" {
                index = endOfBlockComment(in: sql, from: sql.index(after: next))
                continue
            }
            if let closing = closingQuote(for: character) {
                let (value, end) = readQuoted(in: sql, from: index, opening: character, closing: closing)
                tokens.append(
                    SQLiteToken(
                        text: value,
                        range: index..<end,
                        isQuoted: character != "'",
                        isStringLiteral: character == "'"
                    )
                )
                index = end
                continue
            }
            if punctuation.contains(character) {
                let end = sql.index(after: index)
                tokens.append(SQLiteToken(text: String(character), range: index..<end, isQuoted: false, isStringLiteral: false))
                index = end
                continue
            }

            var end = index
            while end < sql.endIndex, !sql[end].isWhitespace,
                  !punctuation.contains(sql[end]), closingQuote(for: sql[end]) == nil {
                end = sql.index(after: end)
            }
            /// A character no rule above claimed and that cannot start a word would otherwise leave
            /// `end` at `index` and loop forever.
            if end == index { end = sql.index(after: index) }
            tokens.append(SQLiteToken(text: String(sql[index..<end]), range: index..<end, isQuoted: false, isStringLiteral: false))
            index = end
        }
        return tokens
    }

    private static func closingQuote(for opening: Character) -> Character? {
        switch opening {
        case "\"": "\""
        case "`": "`"
        case "'": "'"
        case "[": "]"
        default: nil
        }
    }

    private static func endOfBlockComment(in sql: String, from start: String.Index) -> String.Index {
        var index = start
        while index < sql.endIndex {
            let next = sql.index(after: index)
            if sql[index] == "*", next < sql.endIndex, sql[next] == "/" { return sql.index(after: next) }
            index = next
        }
        return sql.endIndex
    }

    /// The identifier or literal starting at `start`, unquoted, and the index just past its closing
    /// quote. An unterminated quote runs to the end of the statement, which is what SQLite's own
    /// lexer does with one.
    private static func readQuoted(
        in sql: String,
        from start: String.Index,
        opening: Character,
        closing: Character
    ) -> (String, String.Index) {
        var value = ""
        var index = sql.index(after: start)
        while index < sql.endIndex {
            let character = sql[index]
            if character == closing {
                let next = sql.index(after: index)
                /// A doubled quote is an escaped one, not the end. Brackets have no escape form.
                if closing != "]", next < sql.endIndex, sql[next] == closing {
                    value.append(character)
                    index = sql.index(after: next)
                    continue
                }
                return (value, next)
            }
            value.append(character)
            index = sql.index(after: index)
        }
        return (value, sql.endIndex)
    }
}
