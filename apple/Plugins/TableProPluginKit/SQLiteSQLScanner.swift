//
//  SQLiteSQLScanner.swift
//  TableProPluginKit
//

import Foundation

// By scalar, as SQLite lexes: a quote or line feed plus a combining mark is one Character. Returns scalar indices.
internal struct SQLiteSQLScanner {
    private let scalars: String.UnicodeScalarView
    private var index: String.Index
    private var quote: Unicode.Scalar?
    private var comment: Comment?

    private enum Comment { case line, block }

    // For the scalar `next()` last returned, delimiters included.
    internal private(set) var isInsideLiteral = false

    internal init(_ text: String, from start: String.Index? = nil) {
        self.scalars = text.unicodeScalars
        self.index = start ?? text.startIndex
    }

    // Trimming the line feed off such text leaves the comment open over whatever is appended after it.
    internal static func endsInLineComment(_ text: String) -> Bool {
        var scanner = SQLiteSQLScanner(text)
        while scanner.next() != nil {}
        return scanner.comment == .line
    }

    // SQLite reads an unterminated quote or block comment to the end of the input, so text appended after it is read inside.
    internal static func endsOpen(_ text: String) -> Bool {
        var scanner = SQLiteSQLScanner(text)
        while scanner.next() != nil {}
        return scanner.quote != nil || scanner.comment == .block
    }

    internal mutating func next() -> String.Index? {
        guard index < scalars.endIndex else { return nil }
        let current = index
        let scalar = scalars[current]
        index = scalars.index(after: current)
        let wasInside = quote != nil || comment != nil
        defer { isInsideLiteral = wasInside || quote != nil || comment != nil }

        switch comment {
        case .line:
            if scalar == "\n" { comment = nil }
            return current
        case .block:
            if scalar == "*", index < scalars.endIndex, scalars[index] == "/" {
                comment = nil
                index = scalars.index(after: index)
            }
            return current
        case nil:
            break
        }

        if let open = quote {
            guard scalar == open else { return current }
            // A doubled quote escapes itself; a bracket has no escape form.
            if index < scalars.endIndex, scalars[index] == open, open != "]" {
                index = scalars.index(after: index)
            } else {
                quote = nil
            }
            return current
        }

        switch scalar {
        case "'", "\"", "`":
            quote = scalar
        case "[":
            quote = "]"
        // SQLite looks for the closer only after the whole opener, so `/*/` opens a comment and does not close it.
        case "-" where index < scalars.endIndex && scalars[index] == "-":
            comment = .line
            index = scalars.index(after: index)
        case "/" where index < scalars.endIndex && scalars[index] == "*":
            comment = .block
            index = scalars.index(after: index)
        default:
            break
        }
        return current
    }
}

// The range lets a rewrite cut one clause and leave every other stored byte as it was.
internal struct SQLiteToken: Equatable {
    // Quotes removed: `"my col"` and `[my col]` both read `my col`.
    internal let text: String
    internal let range: Range<String.Index>
    internal let isQuoted: Bool
    internal let isStringLiteral: Bool

    // A column named `"references"` is not the clause.
    internal var keyword: String { isQuoted || isStringLiteral ? "" : text.uppercased() }

    internal var isPunctuation: Bool {
        guard let scalar = text.unicodeScalars.first, text.unicodeScalars.count == 1 else { return false }
        return SQLiteTokenizer.punctuation.contains(scalar)
    }
}

// Lexes only, so `REFERENCES` inside a literal or a comment never reads as a clause.
internal enum SQLiteTokenizer {
    internal static let punctuation: Set<Unicode.Scalar> = ["(", ")", ",", ";", ".", "+", "*", "/", "%", "<", ">", "=", "!", "|", "&", "~"]

    // Token ranges are scalar ranges of `sql`, so slicing and replacing through them is exact.
    internal static func tokenize(_ sql: String) -> [SQLiteToken] {
        let scalars = sql.unicodeScalars
        var tokens: [SQLiteToken] = []
        var index = scalars.startIndex

        while index < scalars.endIndex {
            let scalar = scalars[index]
            let next = scalars.index(after: index)

            if isWhitespace(scalar) {
                index = next
                continue
            }
            if startsLineComment(in: scalars, at: index) {
                index = scalars[next...].firstIndex(of: "\n").map { scalars.index(after: $0) } ?? scalars.endIndex
                continue
            }
            if scalar == "/", next < scalars.endIndex, scalars[next] == "*" {
                index = endOfBlockComment(in: scalars, from: scalars.index(after: next))
                continue
            }
            if let closing = closingQuote(for: scalar) {
                let (value, end) = readQuoted(in: scalars, from: index, closing: closing)
                tokens.append(
                    SQLiteToken(
                        text: value,
                        range: index..<end,
                        isQuoted: scalar != "'",
                        isStringLiteral: scalar == "'"
                    )
                )
                index = end
                continue
            }
            if punctuation.contains(scalar) {
                tokens.append(SQLiteToken(text: String(scalar), range: index..<next, isQuoted: false, isStringLiteral: false))
                index = next
                continue
            }

            // `INT--x` is a word and a comment: reading it as one word turns the comment into clauses.
            var end = next
            while end < scalars.endIndex, !isWhitespace(scalars[end]),
                  !punctuation.contains(scalars[end]), closingQuote(for: scalars[end]) == nil,
                  !startsLineComment(in: scalars, at: end) {
                end = scalars.index(after: end)
            }
            tokens.append(SQLiteToken(text: String(scalars[index..<end]), range: index..<end, isQuoted: false, isStringLiteral: false))
            index = end
        }
        return tokens
    }

    // SQLite's whitespace: anything else, U+00A0 included, is part of a name.
    internal static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\u{0B}" || scalar == "\u{0C}" || scalar == "\r"
    }

    private static func startsLineComment(in scalars: String.UnicodeScalarView, at index: String.Index) -> Bool {
        let next = scalars.index(after: index)
        return scalars[index] == "-" && next < scalars.endIndex && scalars[next] == "-"
    }

    private static func closingQuote(for opening: Unicode.Scalar) -> Unicode.Scalar? {
        switch opening {
        case "\"": "\""
        case "`": "`"
        case "'": "'"
        case "[": "]"
        default: nil
        }
    }

    private static func endOfBlockComment(in scalars: String.UnicodeScalarView, from start: String.Index) -> String.Index {
        var index = start
        while index < scalars.endIndex {
            let next = scalars.index(after: index)
            if scalars[index] == "*", next < scalars.endIndex, scalars[next] == "/" { return scalars.index(after: next) }
            index = next
        }
        return scalars.endIndex
    }

    // An unterminated quote runs to the end of the statement, as it does in SQLite's own lexer.
    private static func readQuoted(
        in scalars: String.UnicodeScalarView,
        from start: String.Index,
        closing: Unicode.Scalar
    ) -> (String, String.Index) {
        var value = String.UnicodeScalarView()
        var index = scalars.index(after: start)
        while index < scalars.endIndex {
            let scalar = scalars[index]
            let next = scalars.index(after: index)
            if scalar == closing {
                // A doubled quote is an escaped one; a bracket has no escape form.
                guard closing != "]", next < scalars.endIndex, scalars[next] == closing else {
                    return (String(value), next)
                }
                value.append(scalar)
                index = scalars.index(after: next)
                continue
            }
            value.append(scalar)
            index = next
        }
        return (String(value), scalars.endIndex)
    }
}
