//
//  OracleBindPlaceholders.swift
//  OracleDriverPlugin
//

import Foundation
import TableProOracleCore
import TableProPluginKit
import TableProSQLQuoting

// Writes the values for the host's `?` placeholders into an Oracle statement. Each value is written for the type of
// the column it goes into when the host names one, the same way a grid save writes it; else for the kind the user
// gave the parameter; else as the PluginKit default writes untyped text. What no literal can carry is bound as a
// positional `:1 ... :n`, numbered in order: bytes, because Oracle has no `X'..'` literal (ORA-03046), and text over
// the literal limit (ORA-01704). No session NLS setting is changed: a quoted decimal fails with ORA-01722 under
// `NLS_NUMERIC_CHARACTERS = ',.'`, so a number goes in as a validated literal.
//
// Only a `?` that is a placeholder is replaced. One inside a string literal, an alternative-quoted `q'[...]'` literal
// (any delimiter, with or without the national `n` prefix), a double-quoted name such as `"Paid?"`, or a `--` or
// `/* */` comment is text, and replacing it would change the statement and shift every value after it.
internal enum OracleBindPlaceholders {
    /// The longest string literal Oracle parses, in bytes of the value it holds rather than of its doubled quotes
    /// (measured on 23ai with `MAX_STRING_SIZE = STANDARD`: 4,000 bytes parse, 4,001 fail with ORA-01704).
    static let maxLiteralBytes = 4_000

    // A placeholder with no parameter left stays `?`, as the PluginKit default leaves it. Throws for a BFILE value that
    // is not a `BFILENAME` call, which no SQL writes.
    static func substituting(
        _ sql: String,
        parameters: [PluginCellValue],
        kinds: [PluginColumnKind?]? = nil,
        typeNames: [String?]? = nil,
        writesBooleans: Bool = false
    ) throws -> (sql: String, binds: [PluginCellValue]) {
        var binds: [PluginCellValue] = []
        let rewritten = try replacingPlaceholders(in: sql) { index in
            guard index < parameters.count else { return nil }
            let value = parameters[index]
            guard let written = Self.operand(
                for: value,
                kind: kinds.flatMap { $0.indices.contains(index) ? $0[index] : nil },
                typeName: typeNames.flatMap { $0.indices.contains(index) ? $0[index] : nil },
                writesBooleans: writesBooleans,
                bind: {
                    binds.append(value)
                    return ":\(binds.count)"
                }
            ) else {
                throw OraclePluginError(core: .queryFailed(OracleValueKind.unwritableBFileReason))
            }
            return written
        }
        return (rewritten, binds)
    }

    static func operand(
        for value: PluginCellValue,
        kind: PluginColumnKind?,
        typeName: String?,
        writesBooleans: Bool,
        bind: () -> String
    ) -> String? {
        if let typeName {
            return OracleValueKind(typeName: typeName).operand(for: value, bind: bind)
        }
        switch value {
        case .null:
            return "NULL"
        case .bytes:
            return bind()
        case .text(let text):
            return literal(for: text, kind: kind, writesBooleans: writesBooleans) ?? bind()
        }
    }

    // Nil when the text is over the literal limit and has to be bound. Text the kind does not fit is quoted, for the
    // server to refuse. `TRUE` and `FALSE` parse only where SQL has a BOOLEAN type, 23ai on.
    static func literal(for text: String, kind: PluginColumnKind?, writesBooleans: Bool) -> String? {
        guard let kind else {
            // No numeric column reads as `00123` or `-007`, so that text is a code or a zip and stays a string.
            if PluginNumericLiteral.isValid(text), !opensWithPaddingZero(text) { return text }
            return quotedLiteral(text)
        }
        switch kind {
        case .integer, .decimal:
            if OracleNumericLiteral.isValid(text) { return text }
        case .boolean:
            guard writesBooleans else { break }
            switch PluginSQLLiteral.booleanSynonym(for: text, kind: kind) {
            case .isTrue?: return "TRUE"
            case .isFalse?: return "FALSE"
            default: break
            }
        case .text, .other:
            break
        @unknown default:
            break
        }
        return quotedLiteral(text)
    }

    // Nil when the text is over the literal limit and has to be bound. NUL characters are dropped as the PluginKit
    // default drops them. A quote is doubled scalar by scalar, so one carrying a combining mark cannot end the literal.
    static func quotedLiteral(_ text: String) -> String? {
        let kept = text.unicodeScalars.filter { $0 != "\0" }
        guard String(kept).utf8.count <= maxLiteralBytes else { return nil }
        return SQLQuoting.stringLiteral(text)
    }

    // `007`, `-0042`: an integer part that opens with 0 and goes on with another digit.
    private static func opensWithPaddingZero(_ text: String) -> Bool {
        let unsigned = text.unicodeScalars.drop { $0 == "-" || $0 == "+" }
        guard unsigned.first == "0", let next = unsigned.dropFirst().first else { return false }
        return ("0"..."9").contains(next)
    }

    private static func replacingPlaceholders(
        in sql: String,
        with replacement: (Int) throws -> String?
    ) rethrows -> String {
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
            let replaced = try replacement(placeholderIndex)
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
