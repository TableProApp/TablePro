//
//  SqlLexer.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// The character level rules every SQL scanner in the app agrees on: which UTF-16 units matter, and how far a comment,
/// a quoted string or a dollar quoted body runs.
///
/// Scanners differ in what they do with the structure they find, so they are not merged. Offsets are UTF-16 units, so
/// an `NSString` can be walked in constant time per character.
///
/// ``skipQuotedString`` gates backslash escapes on the dialect, which is what PostgreSQL requires.
/// `SQLStatementScanner` deliberately keeps its own ungated handling, because splitting a script for execution is
/// safer when a backslash never ends a string early; `SQLStatementScannerTests` pins that behaviour. Oracle is the
/// exception there: a backslash is never an escape in Oracle, and scripts written for it routinely quote Windows paths.
enum SqlLexer {
    static let space = UInt16(UnicodeScalar(" ").value)
    static let tab = UInt16(UnicodeScalar("\t").value)
    static let newline = UInt16(UnicodeScalar("\n").value)
    static let carriageReturn = UInt16(UnicodeScalar("\r").value)
    static let singleQuote = UInt16(UnicodeScalar("'").value)
    static let doubleQuote = UInt16(UnicodeScalar("\"").value)
    static let backtick = UInt16(UnicodeScalar("`").value)
    static let backslash = UInt16(UnicodeScalar("\\").value)
    static let dash = UInt16(UnicodeScalar("-").value)
    static let slash = UInt16(UnicodeScalar("/").value)
    static let star = UInt16(UnicodeScalar("*").value)
    static let hash = UInt16(UnicodeScalar("#").value)
    static let semicolon = UInt16(UnicodeScalar(";").value)
    static let openParen = UInt16(UnicodeScalar("(").value)
    static let closeParen = UInt16(UnicodeScalar(")").value)
    static let exclamationMark = UInt16(UnicodeScalar("!").value)
    static let smallQ = UInt16(UnicodeScalar("q").value)
    static let capitalQ = UInt16(UnicodeScalar("Q").value)
    static let smallN = UInt16(UnicodeScalar("n").value)
    static let capitalN = UInt16(UnicodeScalar("N").value)
    private static let openBracket = UInt16(UnicodeScalar("[").value)
    private static let closeBracket = UInt16(UnicodeScalar("]").value)
    private static let openBrace = UInt16(UnicodeScalar("{").value)
    private static let closeBrace = UInt16(UnicodeScalar("}").value)
    private static let lessThan = UInt16(UnicodeScalar("<").value)
    private static let greaterThan = UInt16(UnicodeScalar(">").value)

    /// How far a scan ran, and how many lines it crossed. A caller that does not track lines ignores `newlines`.
    struct Span {
        let next: Int
        let newlines: Int
    }

    static func isWhitespace(_ character: UInt16) -> Bool {
        character == space || character == tab || character == newline || character == carriageReturn
    }

    static func isQuote(_ character: UInt16) -> Bool {
        character == singleQuote || character == doubleQuote || character == backtick
    }

    static func startsLineComment(_ text: NSString, at offset: Int, length: Int) -> Bool {
        text.character(at: offset) == dash && offset + 1 < length && text.character(at: offset + 1) == dash
    }

    static func startsBlockComment(_ text: NSString, at offset: Int, length: Int) -> Bool {
        text.character(at: offset) == slash && offset + 1 < length && text.character(at: offset + 1) == star
    }

    /// A MySQL conditional comment, whose body is executed rather than ignored.
    static func startsConditionalComment(_ text: NSString, at offset: Int, length: Int) -> Bool {
        startsBlockComment(text, at: offset, length: length)
            && offset + 2 < length
            && text.character(at: offset + 2) == exclamationMark
    }

    /// The offset of the newline that ends the line, or the end of the document.
    static func endOfLine(_ text: NSString, from offset: Int, length: Int) -> Int {
        var cursor = min(offset, length)
        while cursor < length, text.character(at: cursor) != newline {
            cursor += 1
        }
        return cursor
    }

    /// Runs past `*/`, or to the end of the document when the comment is never closed.
    static func skipBlockComment(_ text: NSString, from offset: Int, length: Int) -> Span {
        var cursor = offset + 2
        var newlines = 0
        while cursor < length {
            let character = text.character(at: cursor)
            if character == newline {
                newlines += 1
            }
            if character == star, cursor + 1 < length, text.character(at: cursor + 1) == slash {
                return Span(next: cursor + 2, newlines: newlines)
            }
            cursor += 1
        }
        return Span(next: length, newlines: newlines)
    }

    static func skipNestedBlockComment(_ text: NSString, from offset: Int, length: Int) -> Span {
        var cursor = offset + 2
        var depth = 1
        var newlines = 0
        while cursor < length {
            let character = text.character(at: cursor)
            if character == newline {
                newlines += 1
            }
            if startsBlockComment(text, at: cursor, length: length) {
                depth += 1
                cursor += 2
                continue
            }
            if character == star, cursor + 1 < length, text.character(at: cursor + 1) == slash {
                depth -= 1
                cursor += 2
                guard depth > 0 else { return Span(next: cursor, newlines: newlines) }
                continue
            }
            cursor += 1
        }
        return Span(next: length, newlines: newlines)
    }

    /// Runs past the closing quote, or to the end of the document when the string is never closed.
    ///
    /// A doubled quote always escapes. A backslash only escapes where the dialect says it does, so `'a\'` ends the
    /// string on PostgreSQL and continues it on MySQL.
    static func skipQuotedString(
        _ text: NSString,
        from offset: Int,
        quote: UInt16,
        length: Int,
        dialect: SqlDialect
    ) -> Span {
        skipQuotedString(
            text,
            from: offset,
            quote: quote,
            length: length,
            backslashEscapes: dialect.requiresBackslashEscapesInSingleQuotes
        )
    }

    static func skipQuotedString(
        _ text: NSString,
        from offset: Int,
        quote: UInt16,
        length: Int,
        backslashEscapes: Bool
    ) -> Span {
        var cursor = offset + 1
        var newlines = 0
        while cursor < length {
            let character = text.character(at: cursor)
            if character == newline {
                newlines += 1
            }
            if backslashEscapes, character == backslash, cursor + 1 < length {
                cursor += 2
                continue
            }
            if character == quote {
                if cursor + 1 < length, text.character(at: cursor + 1) == quote {
                    cursor += 2
                    continue
                }
                return Span(next: cursor + 1, newlines: newlines)
            }
            cursor += 1
        }
        return Span(next: length, newlines: newlines)
    }

    /// Runs past an Oracle `q'<delim>...<delim>'` literal, or its national form `nq'...'`, when one starts at
    /// `offset`.
    ///
    /// The body ends at the closing delimiter followed by a quote, so `q'[it's]'` is one literal although a plain scan
    /// would end it at `it'`. Bracket-like delimiters close with their partner. Returns nil when `offset` does not
    /// start one; a caller must only ask at the start of a word, because `xq'` is an identifier followed by a string.
    static func skipAlternativeQuotedString(_ text: NSString, at offset: Int, length: Int) -> Span? {
        var cursor = offset
        let first = text.character(at: cursor)
        if first == smallN || first == capitalN {
            cursor += 1
        }
        guard cursor + 2 < length else { return nil }
        let prefix = text.character(at: cursor)
        guard prefix == smallQ || prefix == capitalQ, text.character(at: cursor + 1) == singleQuote else { return nil }
        let opener = text.character(at: cursor + 2)
        guard !isWhitespace(opener) else { return nil }
        let closer = alternativeQuoteCloser(for: opener)
        cursor += 3
        var newlines = 0
        while cursor < length {
            let character = text.character(at: cursor)
            if character == newline {
                newlines += 1
            }
            if character == closer, cursor + 1 < length, text.character(at: cursor + 1) == singleQuote {
                return Span(next: cursor + 2, newlines: newlines)
            }
            cursor += 1
        }
        return Span(next: length, newlines: newlines)
    }

    private static func alternativeQuoteCloser(for opener: UInt16) -> UInt16 {
        switch opener {
        case openBracket: return closeBracket
        case openParen: return closeParen
        case openBrace: return closeBrace
        case lessThan: return greaterThan
        default: return opener
        }
    }

    /// Runs to the closing `$tag$`. `bodyEnd` is where the body stops, `next` is past the closing tag.
    static func skipDollarQuotedBody(
        _ text: NSString,
        from bodyStart: Int,
        tag: String,
        length: Int
    ) -> (bodyEnd: Int, span: Span) {
        var cursor = bodyStart
        var newlines = 0
        while cursor < length {
            let character = text.character(at: cursor)
            if character == newline {
                newlines += 1
            }
            if character == SqlDollarQuote.dollar,
               SqlDollarQuote.matchesClose(at: cursor, tag: tag, in: text, bufLen: length) {
                let next = cursor + (tag as NSString).length + 2
                return (cursor, Span(next: next, newlines: newlines))
            }
            cursor += 1
        }
        return (length, Span(next: length, newlines: newlines))
    }
}
