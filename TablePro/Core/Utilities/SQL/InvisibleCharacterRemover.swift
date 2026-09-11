//
//  InvisibleCharacterRemover.swift
//  TablePro
//

import CodeEditTextView
import Foundation

internal enum InvisibleCharacterRemover {
    private static let lineBreaks: Set<UInt32> = [0x85, 0x2028, 0x2029]
    private static let whitespaceControls: Set<UInt32> = [0x0B, 0x0C]

    static func replacements(
        in text: NSString,
        scope: NSRange,
        skippingLiteralsAndComments: Bool,
        rules: SQLLexicalRules,
        lineEnding: String
    ) -> [TextReplacement] {
        let end = min(NSMaxRange(scope), text.length)
        var replacements: [TextReplacement] = []
        var index = max(scope.location, 0)
        while index < end {
            if skippingLiteralsAndComments, let skipTo = SQLNonCodeSpan.end(at: index, in: text, rules: rules) {
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
}
