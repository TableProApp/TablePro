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

        if let end = SQLNonCodeSpan.end(at: index, in: text, rules: rules) {
            index = end
            return
        }
        if SQLNonCodeSpan.isWordUnit(character) {
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
            guard SQLNonCodeSpan.isWordUnit(unit) else { break }
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
    }

    private static func isNativeScriptUnit(_ unit: UInt16) -> Bool {
        guard unit >= 0x80 else { return false }
        guard let scalar = Unicode.Scalar(unit) else { return true }
        return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }
}
