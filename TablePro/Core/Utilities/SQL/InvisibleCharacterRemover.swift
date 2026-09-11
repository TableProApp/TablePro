//
//  InvisibleCharacterRemover.swift
//  TablePro
//

import CodeEditTextView
import Foundation
import TableProPluginKit

internal enum InvisibleCharacterRemover {
    private static let lineBreaks: Set<UInt32> = [0x85, 0x2028, 0x2029]
    private static let whitespaceControls: Set<UInt32> = [0x0B, 0x0C]

    static func replacements(
        in text: NSString,
        scope: NSRange,
        skippingLiteralsAndComments: Bool,
        dialect: SqlDialect,
        lineEnding: String
    ) -> [TextReplacement] {
        let end = min(NSMaxRange(scope), text.length)
        var replacements: [TextReplacement] = []
        var index = max(scope.location, 0)
        while index < end {
            if skippingLiteralsAndComments, let skipTo = endOfLiteralOrComment(at: index, in: text, dialect: dialect) {
                index = skipTo
                continue
            }
            guard let classified = SpecialCharacter.classify(in: text, at: index) else {
                index += 1
                continue
            }
            let cleaned = replacement(for: classified, lineEnding: lineEnding)
            replacements.append(TextReplacement(range: classified.range, string: cleaned))
            index = NSMaxRange(classified.range)
        }
        return replacements
    }

    static func mappedOffset(_ offset: Int, through replacements: [TextReplacement]) -> Int {
        var delta = 0
        for replacement in replacements {
            guard replacement.range.location < offset else { break }
            let replacementLength = (replacement.string as NSString).length
            if NSMaxRange(replacement.range) <= offset {
                delta += replacementLength - replacement.range.length
            } else {
                delta += replacement.range.location + replacementLength - offset
            }
        }
        return offset + delta
    }

    private static func replacement(for classified: ClassifiedSpecialCharacter, lineEnding: String) -> String {
        let value = classified.scalar.value
        if lineBreaks.contains(value) {
            return lineEnding
        }
        if whitespaceControls.contains(value) || classified.character == .blankSpace {
            return " "
        }
        return ""
    }

    private static func endOfLiteralOrComment(at index: Int, in text: NSString, dialect: SqlDialect) -> Int? {
        let length = text.length
        let character = text.character(at: index)
        if SqlLexer.startsLineComment(text, at: index, length: length)
            || (dialect.supportsHashLineComments && character == SqlLexer.hash) {
            return SqlLexer.endOfLine(text, from: index, length: length)
        }
        if SqlLexer.startsBlockComment(text, at: index, length: length) {
            guard !(dialect == .mysql && SqlLexer.startsConditionalComment(text, at: index, length: length)) else {
                return nil
            }
            return SqlLexer.skipBlockComment(text, from: index, length: length).next
        }
        if SqlLexer.isQuote(character) {
            return SqlLexer.skipQuotedString(text, from: index, quote: character, length: length, dialect: dialect).next
        }
        guard dialect.supportsDollarQuotes, character == SqlDollarQuote.dollar,
              case .opener(let openerLength, let tag) = SqlDollarQuote.scanOpener(at: index, in: text, bufLen: length)
        else {
            return nil
        }
        return SqlLexer.skipDollarQuotedBody(text, from: index + openerLength, tag: tag, length: length).span.next
    }
}
