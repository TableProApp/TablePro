//
//  InvisibleCharacterRemover.swift
//  TablePro
//

import Foundation
import TableProSQLGrammar
import TableProTextEngine

internal enum InvisibleCharacterRemover {
    private static let lineBreaks: Set<UInt32> = [0x85, 0x2028, 0x2029]
    private static let whitespaceControls: Set<UInt32> = [0x0B, 0x0C]

    static func replacements(
        in text: NSString,
        scope: NSRange,
        skippingLiteralsAndComments: Bool,
        grammar: SQLLexicalGrammar,
        lineEnding: String
    ) -> [TextReplacement] {
        let end = min(NSMaxRange(scope), text.length)
        var replacements: [TextReplacement] = []
        var index = max(scope.location, 0)
        // Literals are found in the text as cleaned so far, since that is what runs: PostgreSQL reads `SELECT<NBSP>E` as
        // one name, but the cleaned `SELECT E'...'` holds an escape string whose characters stay.
        let cleanedText = skippingLiteralsAndComments ? NSMutableString(string: text as String) : nil
        while index < end {
            if let cleanedText, let skipTo = SQLNonCodeSpan.end(at: index, in: cleanedText, grammar: grammar) {
                index = skipTo
                continue
            }
            guard let classified = SpecialCharacter.classify(in: text, at: index) else {
                index += 1
                continue
            }
            let cleaned = replacement(for: classified, lineEnding: lineEnding)
            replacements.append(TextReplacement(range: classified.range, string: cleaned))
            if let cleanedText {
                let filler = standIn(for: cleaned, replacing: classified.range, in: cleanedText)
                cleanedText.replaceCharacters(in: classified.range, with: filler)
            }
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

    // Keeps offsets: the unit the cleaned text has before the next one, the replacement's last or, for a removed
    // character, the one already before it.
    private static func standIn(for cleaned: String, replacing range: NSRange, in cleanedText: NSString) -> String {
        let replacement = cleaned as NSString
        let unit: UInt16
        if replacement.length > 0 {
            unit = replacement.character(at: replacement.length - 1)
        } else if range.location > 0 {
            unit = cleanedText.character(at: range.location - 1)
        } else {
            unit = SqlLexer.space
        }
        return String(utf16CodeUnits: Array(repeating: unit, count: range.length), count: range.length)
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
}
