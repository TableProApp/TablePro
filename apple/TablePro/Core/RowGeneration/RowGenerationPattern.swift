//
//  RowGenerationPattern.swift
//  TablePro
//

import Foundation

// `#` is a digit, `?` a letter, `*` a letter or digit, and `\` makes the next character literal.
internal enum RowGenerationPattern {
    private enum Token {
        case literal(Character)
        case slot([Character])
    }

    private static let digits = Array("0123456789")
    private static let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    private static let alphanumerics = letters + digits

    private static func tokens(_ pattern: String) -> [Token] {
        var tokens: [Token] = []
        var isEscaped = false
        for character in pattern {
            if isEscaped {
                tokens.append(.literal(character))
                isEscaped = false
                continue
            }
            switch character {
            case "\\": isEscaped = true
            case "#": tokens.append(.slot(digits))
            case "?": tokens.append(.slot(letters))
            case "*": tokens.append(.slot(alphanumerics))
            default: tokens.append(.literal(character))
            }
        }
        return tokens
    }

    internal static func expand(_ pattern: String, using generator: inout SeededGenerator) -> String {
        var result = ""
        for token in tokens(pattern) {
            switch token {
            case .literal(let character): result.append(character)
            case .slot(let choices): result.append(choices[generator.index(below: choices.count)])
            }
        }
        return result
    }

    // The value at one position of every value the pattern can make, counting the last slot fastest.
    internal static func value(at position: Int64, in pattern: String) -> String {
        var remaining = max(0, position)
        var characters: [Character] = []
        for token in tokens(pattern).reversed() {
            switch token {
            case .literal(let character):
                characters.append(character)
            case .slot(let choices):
                characters.append(choices[Int(remaining % Int64(choices.count))])
                remaining /= Int64(choices.count)
            }
        }
        return String(characters.reversed())
    }

    internal static func combinations(_ pattern: String) -> Int64? {
        var total: Int64 = 1
        for case .slot(let choices) in tokens(pattern) {
            let product = total.multipliedReportingOverflow(by: Int64(choices.count))
            guard !product.overflow else { return nil }
            total = product.partialValue
        }
        return total
    }
}
