//
//  OracleBindPlaceholders.swift
//  OracleDriverPlugin
//

import Foundation
import TableProPluginKit

/// Writes the values for the host's `?` placeholders into an Oracle statement.
///
/// A value a literal can carry is written as the literal the PluginKit default has always written, so a statement the
/// host builds (an import, a copy, an MCP write, a query parameter) reads exactly as it did: numeric text unquoted,
/// other text quoted, NULL as `NULL`. What no literal can carry is bound as a positional `:1 ... :n`, numbered in
/// order: bytes, because Oracle has no `X'..'` literal (ORA-03046), and text over the literal limit (ORA-01704).
///
/// Only a `?` that is a placeholder is replaced. One inside a string literal, an alternative-quoted `q'[...]'`
/// literal (any delimiter, with or without the national `n` prefix), a double-quoted name such as `"Paid?"`, or a
/// `--` or `/* */` comment is text, and replacing it would change the statement and shift every value after it.
internal enum OracleBindPlaceholders {
    /// The longest string literal Oracle parses, in bytes of the value it holds rather than of its doubled quotes
    /// (measured on 23ai with `MAX_STRING_SIZE = STANDARD`: 4,000 bytes parse, 4,001 fail with ORA-01704).
    static let maxLiteralBytes = 4_000

    /// The statement with every placeholder replaced, and the values left to bind, in `:n` order. A placeholder with
    /// no parameter left stays `?`, as the PluginKit default leaves it.
    static func substituting(_ sql: String, parameters: [PluginCellValue]) -> (sql: String, binds: [PluginCellValue]) {
        var binds: [PluginCellValue] = []
        let rewritten = replacingPlaceholders(in: sql) { index in
            guard index < parameters.count else { return nil }
            let value = parameters[index]
            if let literal = literal(for: value) { return literal }
            binds.append(value)
            return ":\(binds.count)"
        }
        return (rewritten, binds)
    }

    /// The literal for a value, or nil when it has to be bound. NUL characters are dropped as the PluginKit default
    /// drops them. A quote is doubled scalar by scalar, so one carrying a combining mark cannot end the literal.
    static func literal(for value: PluginCellValue) -> String? {
        switch value {
        case .null:
            return "NULL"
        case .bytes:
            return nil
        case .text(let text):
            return PluginNumericLiteral.isValid(text) ? text : quotedLiteral(text)
        }
    }

    /// The text as a quoted string literal, or nil when it is over the literal limit and has to be bound.
    static func quotedLiteral(_ text: String) -> String? {
        let kept = text.unicodeScalars.filter { $0 != "\0" }
        guard String(kept).utf8.count <= maxLiteralBytes else { return nil }
        var escaped = String.UnicodeScalarView()
        for scalar in kept {
            if scalar == "'" { escaped.append(scalar) }
            escaped.append(scalar)
        }
        return "'\(String(escaped))'"
    }

    private static func replacingPlaceholders(in sql: String, with replacement: (Int) -> String?) -> String {
        let units = Array(sql.utf16)
        var output = ""
        var placeholderIndex = 0
        var copiedUpTo = 0
        var index = 0
        while index < units.count {
            guard units[index] == Unit.question else {
                index = skippedEnd(in: units, from: index)
                continue
            }
            let replaced = replacement(placeholderIndex)
            placeholderIndex += 1
            guard let text = replaced else {
                index += 1
                continue
            }
            output += String(decoding: units[copiedUpTo..<index], as: UTF16.self) + text
            if index + 1 < units.count, isWordUnit(units[index + 1]) {
                output += " "
            }
            index += 1
            copiedUpTo = index
        }
        output += String(decoding: units[copiedUpTo..<units.count], as: UTF16.self)
        return output
    }

    /// Where the token starting at `index` ends: past a literal, quoted name or comment it opens, or one unit on.
    private static func skippedEnd(in units: [UInt16], from index: Int) -> Int {
        let unit = units[index]
        switch unit {
        case Unit.singleQuote where opensAlternativeQuote(in: units, at: index):
            return alternativeQuoteEnd(in: units, from: index)
        case Unit.singleQuote:
            return quotedEnd(in: units, from: index, delimiter: Unit.singleQuote)
        case Unit.doubleQuote:
            return quotedEnd(in: units, from: index, delimiter: Unit.doubleQuote)
        case Unit.hyphen where index + 1 < units.count && units[index + 1] == Unit.hyphen:
            var cursor = index + 2
            while cursor < units.count, units[cursor] != Unit.newline { cursor += 1 }
            return cursor
        case Unit.slash where index + 1 < units.count && units[index + 1] == Unit.star:
            var cursor = index + 2
            while cursor + 1 < units.count {
                if units[cursor] == Unit.star, units[cursor + 1] == Unit.slash { return cursor + 2 }
                cursor += 1
            }
            return units.count
        default:
            return index + 1
        }
    }

    /// A doubled delimiter inside is the escape both string literals and quoted names use.
    private static func quotedEnd(in units: [UInt16], from open: Int, delimiter: UInt16) -> Int {
        var cursor = open + 1
        while cursor < units.count {
            guard units[cursor] == delimiter else {
                cursor += 1
                continue
            }
            guard cursor + 1 < units.count, units[cursor + 1] == delimiter else { return cursor + 1 }
            cursor += 2
        }
        return units.count
    }

    /// `q'` or `nq'` at the start of a word. Such a literal takes no escapes and ends at the partner of the character
    /// after the quote followed by `'`, so `q'[it's ?]'` is one literal.
    private static func opensAlternativeQuote(in units: [UInt16], at quote: Int) -> Bool {
        guard quote >= 1, units[quote - 1] == Unit.lowerQ || units[quote - 1] == Unit.upperQ else { return false }
        let beforePrefix = quote - 2
        guard beforePrefix >= 0 else { return true }
        let isNational = units[beforePrefix] == Unit.lowerN || units[beforePrefix] == Unit.upperN
        guard isNational else { return !isWordUnit(units[beforePrefix]) }
        return beforePrefix == 0 || !isWordUnit(units[beforePrefix - 1])
    }

    private static func alternativeQuoteEnd(in units: [UInt16], from quote: Int) -> Int {
        guard quote + 1 < units.count else { return units.count }
        let closing = closingDelimiter(for: units[quote + 1])
        var cursor = quote + 2
        while cursor + 1 < units.count {
            if units[cursor] == closing, units[cursor + 1] == Unit.singleQuote { return cursor + 2 }
            cursor += 1
        }
        return units.count
    }

    private static let closingPartners: [Unicode.Scalar: Unicode.Scalar] = ["[": "]", "{": "}", "(": ")", "<": ">"]

    private static func closingDelimiter(for opening: UInt16) -> UInt16 {
        guard let scalar = Unicode.Scalar(opening), let partner = closingPartners[scalar] else { return opening }
        return UInt16(partner.value)
    }

    /// A surrogate half belongs to a character outside the BMP and is counted as part of a word, which keeps a `q'`
    /// glued to one from opening an alternative-quoted literal.
    private static func isWordUnit(_ unit: UInt16) -> Bool {
        if UTF16.isLeadSurrogate(unit) || UTF16.isTrailSurrogate(unit) { return true }
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return scalar.properties.isAlphabetic
            || ("0"..."9").contains(scalar)
            || scalar == "_" || scalar == "$" || scalar == "#"
    }

    private enum Unit {
        static let question = UInt16(UInt8(ascii: "?"))
        static let singleQuote = UInt16(UInt8(ascii: "'"))
        static let doubleQuote = UInt16(UInt8(ascii: "\""))
        static let hyphen = UInt16(UInt8(ascii: "-"))
        static let slash = UInt16(UInt8(ascii: "/"))
        static let star = UInt16(UInt8(ascii: "*"))
        static let newline = UInt16(UInt8(ascii: "\n"))
        static let lowerQ = UInt16(UInt8(ascii: "q"))
        static let upperQ = UInt16(UInt8(ascii: "Q"))
        static let lowerN = UInt16(UInt8(ascii: "n"))
        static let upperN = UInt16(UInt8(ascii: "N"))
    }
}
