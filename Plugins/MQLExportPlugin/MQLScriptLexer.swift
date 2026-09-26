//
//  MQLScriptLexer.swift
//  MQLExportPlugin
//

import Foundation

enum MQLScriptToken: Equatable {
    case identifier(String)
    case string(String)
    case number(String)
    case punctuator(Unicode.Scalar)
    case lineComment(String)
    case unreadable
}

struct MQLScriptLexeme: Equatable {
    let token: MQLScriptToken
    let followsLineBreak: Bool
    let followsBlankLine: Bool
}

/// Splits shell text into tokens where JavaScript would: a `//` comment and a string end at the
/// characters the language ends them at, not at the ones the text was expected to hold.
///
/// Only what a collection definition needs is read. Anything else, a regular expression literal,
/// a template string or an operator, comes back as `unreadable`, and a string with an escape it
/// does not know or a raw line break in it does too.
struct MQLScriptLexer {
    private static let punctuators: Set<Unicode.Scalar> = ["{", "}", "[", "]", "(", ")", ",", ":", ";", ".", "-"]
    private static let lineTerminators: Set<Unicode.Scalar> = ["\n", "\r", "\u{2028}", "\u{2029}"]
    private static let spaces: Set<Unicode.Scalar> = [" ", "\t", "\u{0B}", "\u{0C}", "\u{A0}", "\u{FEFF}"]

    private let scalars: [Unicode.Scalar]
    private var index = 0

    private init(scalars: [Unicode.Scalar]) {
        self.scalars = scalars
    }

    static func lexemes(in source: String) -> [MQLScriptLexeme] {
        var lexer = MQLScriptLexer(scalars: Array(source.unicodeScalars))
        var lexemes: [MQLScriptLexeme] = []
        while true {
            let lineBreaks = lexer.skipTrivia()
            guard let token = lexer.nextToken() else { return lexemes }
            lexemes.append(
                MQLScriptLexeme(token: token, followsLineBreak: lineBreaks > 0, followsBlankLine: lineBreaks > 1)
            )
        }
    }

    // MARK: - Trivia

    private mutating func skipTrivia() -> Int {
        var lineBreaks = 0
        while let scalar = peek() {
            if Self.lineTerminators.contains(scalar) {
                index += scalar == "\r" && peek(1) == "\n" ? 2 : 1
                lineBreaks += 1
            } else if Self.spaces.contains(scalar) || scalar.properties.generalCategory == .spaceSeparator {
                index += 1
            } else if scalar == "/", peek(1) == "*" {
                lineBreaks += skipBlockComment()
            } else {
                break
            }
        }
        return lineBreaks
    }

    private mutating func skipBlockComment() -> Int {
        index += 2
        var lineBreaks = 0
        while let scalar = peek() {
            if scalar == "*", peek(1) == "/" {
                index += 2
                return lineBreaks
            }
            if Self.lineTerminators.contains(scalar) { lineBreaks += 1 }
            index += 1
        }
        return lineBreaks
    }

    // MARK: - Tokens

    private mutating func nextToken() -> MQLScriptToken? {
        guard let scalar = peek() else { return nil }
        if scalar == "/", peek(1) == "/" { return lineComment() }
        if scalar == "\"" || scalar == "'" { return string(quotedBy: scalar) }
        if Self.isDigit(scalar) || (scalar == "." && peek(1).map(Self.isDigit) == true) { return number() }
        if Self.isIdentifierStart(scalar) { return identifier() }
        index += 1
        return Self.punctuators.contains(scalar) ? .punctuator(scalar) : .unreadable
    }

    private mutating func lineComment() -> MQLScriptToken {
        index += 2
        var text = String.UnicodeScalarView()
        while let scalar = peek(), !Self.lineTerminators.contains(scalar) {
            text.append(scalar)
            index += 1
        }
        return .lineComment(String(text))
    }

    /// A raw line feed or carriage return ends the token unread and is left for the trivia, so the
    /// next line is read on its own. A raw U+2028 or U+2029 is part of the string, as it is in
    /// JavaScript since ES2019.
    private mutating func string(quotedBy quote: Unicode.Scalar) -> MQLScriptToken {
        index += 1
        var value = String.UnicodeScalarView()
        var isReadable = true
        while let scalar = peek(), scalar != "\n", scalar != "\r" {
            index += 1
            if scalar == quote {
                return isReadable ? .string(String(value)) : .unreadable
            }
            guard scalar == "\\" else {
                value.append(scalar)
                continue
            }
            if let escaped = escapedScalar() {
                value.append(escaped)
            } else {
                isReadable = false
            }
        }
        return .unreadable
    }

    private mutating func escapedScalar() -> Unicode.Scalar? {
        guard let scalar = peek() else { return nil }
        index += 1
        switch scalar {
        case "\"", "'", "\\", "/": return scalar
        case "b": return "\u{08}"
        case "f": return "\u{0C}"
        case "n": return "\n"
        case "r": return "\r"
        case "t": return "\t"
        case "v": return "\u{0B}"
        case "0": return peek().map(Self.isDigit) == true ? nil : "\u{00}"
        case "x": return hexScalar(digits: 2)
        case "u": return unicodeEscape()
        default: return nil
        }
    }

    private mutating func unicodeEscape() -> Unicode.Scalar? {
        if peek() == "{" {
            index += 1
            var digits = ""
            while let scalar = peek(), scalar != "}", digits.count < 7 {
                digits.unicodeScalars.append(scalar)
                index += 1
            }
            guard peek() == "}", !digits.isEmpty, let value = UInt32(digits, radix: 16) else { return nil }
            index += 1
            return Unicode.Scalar(value)
        }
        guard let unit = hexValue(digits: 4) else { return nil }
        guard (0xD800 ... 0xDBFF).contains(unit) else { return Unicode.Scalar(unit) }
        guard peek() == "\\", peek(1) == "u" else { return nil }
        index += 2
        guard let low = hexValue(digits: 4), (0xDC00 ... 0xDFFF).contains(low) else { return nil }
        return Unicode.Scalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00))
    }

    private mutating func hexScalar(digits: Int) -> Unicode.Scalar? {
        hexValue(digits: digits).flatMap(Unicode.Scalar.init)
    }

    private mutating func hexValue(digits: Int) -> UInt32? {
        guard index + digits <= scalars.count else { return nil }
        var text = ""
        text.unicodeScalars.append(contentsOf: scalars[index ..< index + digits])
        guard text.unicodeScalars.allSatisfy(\.properties.isASCIIHexDigit), let value = UInt32(text, radix: 16) else {
            return nil
        }
        index += digits
        return value
    }

    /// Reads the whole run a number could be, letters included, and leaves the grammar to the
    /// reader, so `0x1F` or `1n` is one token that fails there instead of two that might not.
    private mutating func number() -> MQLScriptToken {
        var text = String.UnicodeScalarView()
        while let scalar = peek() {
            let signsExponent = (scalar == "+" || scalar == "-") && (text.last == "e" || text.last == "E")
            guard Self.isIdentifierPart(scalar) || scalar == "." || signsExponent else { break }
            text.append(scalar)
            index += 1
        }
        return .number(String(text))
    }

    private mutating func identifier() -> MQLScriptToken {
        var name = String.UnicodeScalarView()
        while let scalar = peek(), Self.isIdentifierPart(scalar) {
            name.append(scalar)
            index += 1
        }
        return .identifier(String(name))
    }

    // MARK: - Scalars

    private func peek(_ offset: Int = 0) -> Unicode.Scalar? {
        let position = index + offset
        return position < scalars.count ? scalars[position] : nil
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("0" ... "9").contains(scalar)
    }

    private static func isIdentifierStart(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "$" || scalar == "_" || scalar.properties.isXIDStart
    }

    private static func isIdentifierPart(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "$" || scalar == "_" || scalar == "\u{200C}" || scalar == "\u{200D}" || scalar.properties.isXIDContinue
    }
}
