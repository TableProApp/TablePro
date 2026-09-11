//
//  SQLNonCodeSpan.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum SQLNonCodeSpan {
    private static let openBracket = UInt16(UnicodeScalar("[").value)
    private static let closeBracket = UInt16(UnicodeScalar("]").value)
    private static let capitalE = UInt16(UnicodeScalar("E").value)
    private static let smallE = UInt16(UnicodeScalar("e").value)

    static func end(at index: Int, in text: NSString, rules: SQLLexicalRules) -> Int? {
        let length = text.length
        guard index >= 0, index < length else { return nil }
        let character = text.character(at: index)

        if SqlLexer.startsLineComment(text, at: index, length: length)
            || (rules.dialect.supportsHashLineComments && character == SqlLexer.hash) {
            return SqlLexer.endOfLine(text, from: index, length: length)
        }
        if SqlLexer.startsBlockComment(text, at: index, length: length) {
            return endOfBlockComment(at: index, in: text, rules: rules)
        }
        if SqlLexer.isQuote(character) {
            return SqlLexer.skipQuotedString(
                text,
                from: index,
                quote: character,
                length: length,
                backslashEscapes: rules.backslashEscapes
            ).next
        }
        if let end = endOfEscapeString(at: index, in: text, rules: rules) {
            return end
        }
        if rules.bracketsDelimitIdentifiers, character == openBracket {
            return endOfBracketedIdentifier(at: index, in: text)
        }
        return endOfDollarQuotedBody(at: index, in: text, rules: rules)
    }

    static func isWordUnit(_ unit: UInt16) -> Bool {
        if unit < 0x80 {
            return SqlDollarQuote.isIdentifierPart(unit)
        }
        return ConfusableSQLCharacter.separating(unit) == nil
    }

    private static func endOfBlockComment(at index: Int, in text: NSString, rules: SQLLexicalRules) -> Int? {
        let length = text.length
        switch rules.dialect {
        case .mysql where SqlLexer.startsConditionalComment(text, at: index, length: length):
            return nil
        case .postgres:
            return SqlLexer.skipNestedBlockComment(text, from: index, length: length).next
        default:
            return SqlLexer.skipBlockComment(text, from: index, length: length).next
        }
    }

    private static func endOfEscapeString(at index: Int, in text: NSString, rules: SQLLexicalRules) -> Int? {
        let length = text.length
        let character = text.character(at: index)
        guard rules.dialect.supportsEscapeStringPrefix,
              character == capitalE || character == smallE,
              index + 1 < length,
              text.character(at: index + 1) == SqlLexer.singleQuote,
              index == 0 || !isWordUnit(text.character(at: index - 1))
        else {
            return nil
        }
        return SqlLexer.skipQuotedString(
            text,
            from: index + 1,
            quote: SqlLexer.singleQuote,
            length: length,
            backslashEscapes: true
        ).next
    }

    private static func endOfBracketedIdentifier(at index: Int, in text: NSString) -> Int {
        let length = text.length
        var cursor = index + 1
        while cursor < length {
            guard text.character(at: cursor) == closeBracket else {
                cursor += 1
                continue
            }
            guard cursor + 1 < length, text.character(at: cursor + 1) == closeBracket else {
                return cursor + 1
            }
            cursor += 2
        }
        return length
    }

    private static func endOfDollarQuotedBody(at index: Int, in text: NSString, rules: SQLLexicalRules) -> Int? {
        let length = text.length
        guard rules.dialect.supportsDollarQuotes, text.character(at: index) == SqlDollarQuote.dollar,
              case .opener(let openerLength, let tag) = SqlDollarQuote.scanOpener(at: index, in: text, bufLen: length)
        else {
            return nil
        }
        return SqlLexer.skipDollarQuotedBody(text, from: index + openerLength, tag: tag, length: length).span.next
    }
}
