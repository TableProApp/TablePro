//
//  SQLConfusableCharacterScanner.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum SQLConfusableCharacterScanner {
    static func scan(_ text: NSString, rules: SQLLexicalRules) -> [ConfusableSQLCharacterMatch] {
        var scan = ConfusableCharacterScan(text: text, rules: rules)
        scan.run()
        return scan.matches
    }
}

private struct ConfusableCharacterScan {
    private static let openBracket = UInt16(UnicodeScalar("[").value)
    private static let closeBracket = UInt16(UnicodeScalar("]").value)
    private static let capitalE = UInt16(UnicodeScalar("E").value)
    private static let smallE = UInt16(UnicodeScalar("e").value)

    private let text: NSString
    private let length: Int
    private let rules: SQLLexicalRules

    private(set) var matches: [ConfusableSQLCharacterMatch] = []
    private var index = 0

    init(text: NSString, rules: SQLLexicalRules) {
        self.text = text
        self.length = text.length
        self.rules = rules
    }

    mutating func run() {
        while index < length {
            step()
        }
    }

    private mutating func step() {
        let character = text.character(at: index)

        if let end = endOfCommentOrQuotedText(startingWith: character) {
            index = end
            return
        }
        if Self.isWordUnit(character) {
            consumeWord()
            return
        }
        if let confusable = ConfusableSQLCharacter.separating(character) {
            consumeRun(of: character, as: confusable)
            return
        }
        index += 1
    }

    private mutating func consumeRun(of character: UInt16, as confusable: ConfusableSQLCharacter) {
        let start = index
        while index < length, text.character(at: index) == character {
            index += 1
        }
        matches.append(ConfusableSQLCharacterMatch(
            character: confusable,
            range: NSRange(location: start, length: index - start)
        ))
    }

    private mutating func consumeWord() {
        let start = index
        var firstFullWidth: Int?
        var lastFullWidth = start
        var isNativeScript = false

        while index < length {
            let unit = text.character(at: index)
            guard Self.isWordUnit(unit) else { break }
            if ConfusableSQLCharacter.isFullWidthWordUnit(unit) {
                firstFullWidth = firstFullWidth ?? index
                lastFullWidth = index
            } else if Self.isNativeScriptUnit(unit) {
                isNativeScript = true
            }
            index += 1
        }

        if let firstFullWidth, !isNativeScript {
            let range = NSRange(location: firstFullWidth, length: lastFullWidth - firstFullWidth + 1)
            let spelling = ConfusableSQLCharacter.asciiSpelling(of: text, in: range)
            matches.append(ConfusableSQLCharacterMatch(character: .fullWidthText(asciiSpelling: spelling), range: range))
        }

        skipEscapeString(afterWordStartingAt: start)
    }

    private mutating func skipEscapeString(afterWordStartingAt start: Int) {
        guard rules.dialect.supportsEscapeStringPrefix, index - start == 1, index < length,
              text.character(at: index) == SqlLexer.singleQuote else { return }
        let prefix = text.character(at: start)
        guard prefix == Self.capitalE || prefix == Self.smallE else { return }
        index = SqlLexer.skipQuotedString(
            text,
            from: index,
            quote: SqlLexer.singleQuote,
            length: length,
            backslashEscapes: true
        ).next
    }

    private func endOfCommentOrQuotedText(startingWith character: UInt16) -> Int? {
        if SqlLexer.startsLineComment(text, at: index, length: length)
            || (rules.dialect.supportsHashLineComments && character == SqlLexer.hash) {
            return SqlLexer.endOfLine(text, from: index, length: length)
        }
        if SqlLexer.startsBlockComment(text, at: index, length: length) {
            return endOfBlockComment()
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
        if rules.bracketsDelimitIdentifiers, character == Self.openBracket {
            return endOfBracketedIdentifier()
        }
        return endOfDollarQuotedBody(startingWith: character)
    }

    private func endOfBlockComment() -> Int? {
        switch rules.dialect {
        case .mysql where SqlLexer.startsConditionalComment(text, at: index, length: length):
            return nil
        case .postgres:
            return SqlLexer.skipNestedBlockComment(text, from: index, length: length).next
        default:
            return SqlLexer.skipBlockComment(text, from: index, length: length).next
        }
    }

    private func endOfBracketedIdentifier() -> Int {
        var cursor = index + 1
        while cursor < length {
            guard text.character(at: cursor) == Self.closeBracket else {
                cursor += 1
                continue
            }
            guard cursor + 1 < length, text.character(at: cursor + 1) == Self.closeBracket else {
                return cursor + 1
            }
            cursor += 2
        }
        return length
    }

    private func endOfDollarQuotedBody(startingWith character: UInt16) -> Int? {
        guard rules.dialect.supportsDollarQuotes, character == SqlDollarQuote.dollar,
              case .opener(let openerLength, let tag) = SqlDollarQuote.scanOpener(at: index, in: text, bufLen: length)
        else {
            return nil
        }
        return SqlLexer.skipDollarQuotedBody(text, from: index + openerLength, tag: tag, length: length).span.next
    }

    private static func isWordUnit(_ unit: UInt16) -> Bool {
        if unit < 0x80 {
            return SqlDollarQuote.isIdentifierPart(unit)
        }
        return ConfusableSQLCharacter.separating(unit) == nil
    }

    private static func isNativeScriptUnit(_ unit: UInt16) -> Bool {
        guard unit >= 0x80 else { return false }
        guard let scalar = Unicode.Scalar(unit) else { return true }
        return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }
}
