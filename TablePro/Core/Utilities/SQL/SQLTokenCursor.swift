//
//  SQLTokenCursor.swift
//  TablePro
//

import Foundation
import TableProPluginKit

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
    private static let capitalE = UInt16(UnicodeScalar("E").value)
    private static let smallE = UInt16(UnicodeScalar("e").value)
    private static let capitalM = UInt16(UnicodeScalar("M").value)
    private static let smallM = UInt16(UnicodeScalar("m").value)
    private static let digitZero = UInt16(UnicodeScalar("0").value)
    private static let digitNine = UInt16(UnicodeScalar("9").value)

    private let text: NSString
    private let rules: SQLLexicalRules
    private let length: Int
    private var index: Int
    private var conditionalDepth = 0

    internal private(set) var parenDepth = 0

    internal init(_ text: NSString, rules: SQLLexicalRules) {
        self.text = text
        self.rules = rules
        length = text.length
        index = 0
    }

    internal init(_ text: String, rules: SQLLexicalRules) {
        self.init(text as NSString, rules: rules)
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
        if rules.dialect == .mysql {
            if let opener = conditionalCommentOpener(at: index) {
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
        guard startsComment(character) else { return false }
        index = SQLNonCodeSpan.end(at: index, in: text, rules: rules) ?? length
        return true
    }

    private func startsComment(_ character: UInt16) -> Bool {
        if rules.dialect.supportsHashLineComments, character == SqlLexer.hash { return true }
        return SqlLexer.startsLineComment(text, at: index, length: length)
            || SqlLexer.startsBlockComment(text, at: index, length: length)
    }

    private func conditionalCommentOpener(at offset: Int) -> Int? {
        guard SqlLexer.startsBlockComment(text, at: offset, length: length) else { return nil }
        var cursor = offset + 2
        if cursor < length, text.character(at: cursor) == Self.capitalM || text.character(at: cursor) == Self.smallM {
            cursor += 1
        }
        guard cursor < length, text.character(at: cursor) == SqlLexer.exclamationMark else { return nil }
        cursor += 1
        while cursor < length, isDigit(text.character(at: cursor)) {
            cursor += 1
        }
        return cursor - offset
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
        if SqlLexer.isQuote(character) || (rules.bracketsDelimitIdentifiers && character == Self.openBracket) {
            let start = index
            index = SQLNonCodeSpan.end(at: index, in: text, rules: rules) ?? length
            guard character != SqlLexer.singleQuote else { return .literal }
            return .quotedIdentifier(quotedBody(from: start, to: index))
        }
        if startsLiteralSpan(at: index) {
            index = SQLNonCodeSpan.end(at: index, in: text, rules: rules) ?? length
            return .literal
        }
        if isWordUnit(character) { return .word(readWord()) }
        if character == Self.colon, index + 1 < length, text.character(at: index + 1) == Self.equals {
            index += 2
            return .symbol(Self.equals)
        }
        index += 1
        return .symbol(character)
    }

    private func startsLiteralSpan(at offset: Int) -> Bool {
        let character = text.character(at: offset)
        if rules.dialect.supportsEscapeStringPrefix,
           character == Self.capitalE || character == Self.smallE,
           offset + 1 < length, text.character(at: offset + 1) == SqlLexer.singleQuote,
           offset == 0 || !SQLNonCodeSpan.isWordUnit(text.character(at: offset - 1)) {
            return true
        }
        guard rules.dialect.supportsDollarQuotes, character == SqlDollarQuote.dollar,
              case .opener = SqlDollarQuote.scanOpener(at: offset, in: text, bufLen: length)
        else {
            return false
        }
        return true
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

    private func isDigit(_ character: UInt16) -> Bool {
        character >= Self.digitZero && character <= Self.digitNine
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
