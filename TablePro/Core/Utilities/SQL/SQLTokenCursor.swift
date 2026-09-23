//
//  SQLTokenCursor.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar

/// A lazy reader over the head of one statement, in the vocabulary a rule about that statement
/// needs: words, quoted identifiers, literals and single symbols.
///
/// It never materializes the statement. A rule pulls the two or three tokens it cares about and
/// stops, which is what keeps a 100,000-statement dump affordable, and it shares ``SQLNonCodeSpan``
/// with every other scanner so a comment, a string and a dollar-quoted body end in the same place.
///
/// The cursor ends at a depth-0 `;`, so a statement carrying a trailing fragment cannot be read as
/// two. A MySQL conditional comment is code, not a comment, so its `/*!NNNNN` and `/*M!NNNNN`
/// openers and the `*/` that closes them are stepped over and the body is read.
///
/// It is a struct with value semantics, so a rule that needs to look ahead copies it, reads, and
/// either adopts the copy or drops it.
internal struct SQLTokenCursor {
    internal enum Token: Equatable {
        case word(String)
        case quotedIdentifier(String)
        case literal
        case symbol(UInt16)
    }

    internal static let equals = UInt16(UnicodeScalar("=").value)
    internal static let comma = UInt16(UnicodeScalar(",").value)
    internal static let period = UInt16(UnicodeScalar(".").value)
    internal static let openParen = SqlLexer.openParen
    internal static let closeParen = SqlLexer.closeParen

    private static let at = UInt16(UnicodeScalar("@").value)
    private static let colon = UInt16(UnicodeScalar(":").value)
    private static let openBracket = UInt16(UnicodeScalar("[").value)

    private let text: NSString
    private let grammar: SQLLexicalGrammar
    private let length: Int
    private var index: Int
    private var conditionalDepth = 0

    internal private(set) var parenDepth = 0

    internal var location: Int { index }

    internal init(_ text: NSString, grammar: SQLLexicalGrammar) {
        self.text = text
        self.grammar = grammar
        length = text.length
        index = 0
    }

    internal init(_ text: String, grammar: SQLLexicalGrammar) {
        self.init(text as NSString, grammar: grammar)
    }

    internal mutating func next() -> Token? {
        while index < length {
            let character = text.character(at: index)
            if SqlLexer.isWhitespace(character) {
                index += 1
                continue
            }
            if skipsNonCode(character) { continue }
            if character == SqlLexer.semicolon, parenDepth == 0 { return nil }
            return token(startingWith: character)
        }
        return nil
    }

    internal func peek() -> Token? {
        var lookahead = self
        return lookahead.next()
    }

    private mutating func skipsNonCode(_ character: UInt16) -> Bool {
        if grammar.contains(.executableComments) {
            if let opener = SqlLexer.executableCommentOpenerLength(text, at: index, length: length) {
                index += opener
                conditionalDepth += 1
                return true
            }
            if conditionalDepth > 0, character == SqlLexer.star,
               index + 1 < length, text.character(at: index + 1) == SqlLexer.slash {
                index += 2
                conditionalDepth -= 1
                return true
            }
        }
        guard let span = SQLNonCodeSpan.span(at: index, in: text, grammar: grammar), span.kind.isComment else {
            return false
        }
        index = max(span.end, index + 1)
        return true
    }

    private mutating func token(startingWith character: UInt16) -> Token? {
        if character == Self.openParen {
            index += 1
            parenDepth += 1
            return .symbol(character)
        }
        if character == Self.closeParen {
            index += 1
            parenDepth = max(0, parenDepth - 1)
            return .symbol(character)
        }
        if let span = SQLNonCodeSpan.span(at: index, in: text, grammar: grammar), !span.kind.isComment {
            let start = index
            index = max(span.end, index + 1)
            let delimitsIdentifier = character == SqlLexer.doubleQuote || character == SqlLexer.backtick
                || character == Self.openBracket
            guard span.kind == .quoted, delimitsIdentifier else { return .literal }
            return .quotedIdentifier(quotedBody(from: start, to: index))
        }
        if isWordUnit(character) { return .word(readWord()) }
        if character == Self.colon, index + 1 < length, text.character(at: index + 1) == Self.equals {
            index += 2
            return .symbol(Self.equals)
        }
        index += 1
        return .symbol(character)
    }

    private mutating func readWord() -> String {
        let start = index
        while index < length, isWordUnit(text.character(at: index)) {
            index += 1
        }
        return text.substring(with: NSRange(location: start, length: index - start)).uppercased()
    }

    private func quotedBody(from start: Int, to end: Int) -> String {
        guard end - start >= 2 else { return "" }
        let body = text.substring(with: NSRange(location: start + 1, length: end - start - 2))
        guard let closer = closingDelimiter(for: text.character(at: start)) else { return body }
        return body.replacingOccurrences(of: "\(closer)\(closer)", with: String(closer))
    }

    private func closingDelimiter(for opener: UInt16) -> Character? {
        switch opener {
        case SqlLexer.doubleQuote:
            return "\""
        case SqlLexer.backtick:
            return "`"
        case Self.openBracket:
            return "]"
        default:
            return nil
        }
    }

    private func isWordUnit(_ character: UInt16) -> Bool {
        SQLNonCodeSpan.isWordUnit(character) || character == Self.at || character == SqlDollarQuote.dollar
    }
}

internal extension SQLTokenCursor.Token {
    var word: String? {
        guard case .word(let word) = self else { return nil }
        return word
    }

    /// The name this token spells, whichever way it was written. A quoted identifier is uppercased
    /// so `` `sql_log_bin` `` and `SQL_LOG_BIN` answer the same rule.
    var identifier: String? {
        switch self {
        case .word(let word):
            return word
        case .quotedIdentifier(let name):
            return name.uppercased()
        case .literal, .symbol:
            return nil
        }
    }

    func isSymbol(_ expected: UInt16) -> Bool {
        guard case .symbol(let symbol) = self else { return false }
        return symbol == expected
    }
}
