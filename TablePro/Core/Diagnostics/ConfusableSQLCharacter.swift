//
//  ConfusableSQLCharacter.swift
//  TablePro
//

import Foundation

enum ConfusableSQLCharacter: Equatable, Sendable {
    case fullWidthPunctuation(Unicode.Scalar)
    case fullWidthText(asciiSpelling: String)
    case curlyQuote(Unicode.Scalar)
    case nonASCIISpace(Unicode.Scalar)

    private static let fullWidthForms: ClosedRange<UInt16> = 0xFF01...0xFF5E
    private static let fullWidthOffset: UInt16 = 0xFEE0

    static func isFullWidthWordUnit(_ unit: UInt16) -> Bool {
        switch unit {
        case 0xFF10...0xFF19, 0xFF21...0xFF3A, 0xFF3F, 0xFF41...0xFF5A:
            return true
        default:
            return false
        }
    }

    static func separating(_ unit: UInt16) -> ConfusableSQLCharacter? {
        guard let scalar = Unicode.Scalar(unit) else { return nil }
        switch unit {
        case fullWidthForms where !isFullWidthWordUnit(unit):
            return .fullWidthPunctuation(scalar)
        case 0x2018, 0x2019, 0x201C, 0x201D:
            return .curlyQuote(scalar)
        case 0x00A0, 0x2000...0x200A, 0x202F, 0x205F, 0x3000:
            return .nonASCIISpace(scalar)
        default:
            return nil
        }
    }

    static func asciiSpelling(of text: NSString, in range: NSRange) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(range.length)
        for offset in range.location..<NSMaxRange(range) {
            let unit = text.character(at: offset)
            units.append(fullWidthForms.contains(unit) ? unit - fullWidthOffset : unit)
        }
        return String(decoding: units, as: UTF16.self)
    }

    var message: String {
        switch self {
        case .fullWidthPunctuation(let scalar):
            return Self.fullWidthPunctuationMessage(scalar)
        case .fullWidthText(let asciiSpelling):
            return String(
                format: String(localized: "Full-width letters or digits. SQL needs the ASCII %@."),
                asciiSpelling
            )
        case .curlyQuote(let scalar):
            return String(
                format: String(localized: "Curly quote (%1$@). SQL needs the straight quote (%2$@)."),
                Self.codePoint(scalar.value),
                Self.codePoint(Self.straightQuote(for: scalar))
            )
        case .nonASCIISpace(let scalar):
            return String(
                format: String(localized: "Non-ASCII space (%@). SQL needs an ASCII space (U+0020)."),
                Self.codePoint(scalar.value)
            )
        }
    }

    private static func fullWidthPunctuationMessage(_ scalar: Unicode.Scalar) -> String {
        let asciiValue = scalar.value - UInt32(fullWidthOffset)
        guard let ascii = Unicode.Scalar(asciiValue), ascii != ";" else {
            return String(localized: "Full-width semicolon (U+FF1B). SQL reads only ; as a statement separator.")
        }
        return String(
            format: String(localized: "Full-width %1$@ (%2$@). SQL needs the ASCII %1$@ (%3$@)."),
            punctuationName(ascii),
            codePoint(scalar.value),
            codePoint(asciiValue)
        )
    }

    private static func straightQuote(for scalar: Unicode.Scalar) -> UInt32 {
        switch scalar.value {
        case 0x201C, 0x201D:
            return 0x22
        default:
            return 0x27
        }
    }

    private static func codePoint(_ value: UInt32) -> String {
        String(format: "U+%04X", value)
    }

    private static func punctuationName(_ ascii: Unicode.Scalar) -> String {
        switch ascii {
        case "!": return String(localized: "exclamation mark")
        case "\"": return String(localized: "quotation mark")
        case "#": return String(localized: "number sign")
        case "$": return String(localized: "dollar sign")
        case "%": return String(localized: "percent sign")
        case "&": return String(localized: "ampersand")
        case "'": return String(localized: "apostrophe")
        case "(": return String(localized: "left parenthesis")
        case ")": return String(localized: "right parenthesis")
        case "*": return String(localized: "asterisk")
        case "+": return String(localized: "plus sign")
        case ",": return String(localized: "comma")
        case "-": return String(localized: "hyphen")
        case ".": return String(localized: "period")
        case "/": return String(localized: "slash")
        case ":": return String(localized: "colon")
        case "<": return String(localized: "less-than sign")
        case "=": return String(localized: "equals sign")
        case ">": return String(localized: "greater-than sign")
        case "?": return String(localized: "question mark")
        case "@": return String(localized: "at sign")
        case "[": return String(localized: "left square bracket")
        case "\\": return String(localized: "backslash")
        case "]": return String(localized: "right square bracket")
        case "^": return String(localized: "caret")
        case "`": return String(localized: "backtick")
        case "{": return String(localized: "left curly bracket")
        case "|": return String(localized: "vertical bar")
        case "}": return String(localized: "right curly bracket")
        case "~": return String(localized: "tilde")
        default: return String(ascii)
        }
    }
}

struct ConfusableSQLCharacterMatch: Equatable, Sendable {
    let character: ConfusableSQLCharacter
    let range: NSRange
}
