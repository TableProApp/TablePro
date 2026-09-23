//
//  SQLFeatureLexer.swift
//  TableProPluginKit
//

import Foundation

/// Where a comment, a literal or a quoted identifier ends, read by ``SQLLexicalFeatures``.
///
/// This is the plugin side of the app's lexer: a plugin cannot link the app's package, so the kit carries the same
/// rules for the text a driver reads itself. The app's tests run one corpus through both.
struct SQLFeatureLexer {
    enum Kind: Equatable {
        case comment
        case executableComment
        case quoted
    }

    struct Span: Equatable {
        let kind: Kind
        let end: Int
    }

    private static let space: UInt16 = 0x20
    private static let newline: UInt16 = 0x0A
    private static let carriageReturn: UInt16 = 0x0D
    private static let singleQuote: UInt16 = 0x27
    private static let doubleQuote: UInt16 = 0x22
    private static let backtick: UInt16 = 0x60
    private static let backslash: UInt16 = 0x5C
    private static let dash: UInt16 = 0x2D
    private static let slash: UInt16 = 0x2F
    private static let star: UInt16 = 0x2A
    private static let hash: UInt16 = 0x23
    private static let dollar: UInt16 = 0x24
    private static let openBracket: UInt16 = 0x5B
    private static let closeBracket: UInt16 = 0x5D
    private static let openParen: UInt16 = 0x28
    private static let closeParen: UInt16 = 0x29
    private static let openBrace: UInt16 = 0x7B
    private static let closeBrace: UInt16 = 0x7D
    private static let lessThan: UInt16 = 0x3C
    private static let greaterThan: UInt16 = 0x3E
    private static let exclamationMark: UInt16 = 0x21
    private static let at: UInt16 = 0x40
    private static let colon: UInt16 = 0x3A

    let units: [UInt16]
    let features: SQLLexicalFeatures

    init(_ text: String, features: SQLLexicalFeatures) {
        self.units = Array(text.utf16)
        self.features = features
    }

    var count: Int {
        units.count
    }

    func span(at index: Int) -> Span? {
        guard index < units.count else { return nil }
        let unit = units[index]
        if let comment = commentSpan(at: index, unit: unit) {
            return comment
        }
        if unit == Self.singleQuote || unit == Self.doubleQuote
            || (unit == Self.backtick && features.contains(.backtickQuotes)) {
            return Span(kind: .quoted, end: quotedEnd(at: index, quote: unit))
        }
        if unit == Self.openBracket, features.contains(.bracketQuotedIdentifiers) {
            return Span(kind: .quoted, end: bracketEnd(at: index))
        }
        if let prefixed = prefixedLiteralEnd(at: index, unit: unit) {
            return Span(kind: .quoted, end: prefixed)
        }
        if unit == Self.dollar, let dollarEnd = dollarQuotedEnd(at: index) {
            return Span(kind: .quoted, end: dollarEnd)
        }
        guard features.contains(.parenthesizedParameterNames), let parameterEnd = parameterEnd(at: index) else {
            return nil
        }
        return Span(kind: .quoted, end: parameterEnd)
    }

    // MARK: - Comments

    private func commentSpan(at index: Int, unit: UInt16) -> Span? {
        if startsLineComment(at: index, unit: unit) {
            return Span(kind: .comment, end: lineCommentEnd(from: index))
        }
        guard unit == Self.slash, unitAt(index + 1) == Self.star else { return nil }
        if features.contains(.executableComments), isExecutableCommentOpener(at: index) {
            return Span(kind: .executableComment, end: executableCommentEnd(from: index))
        }
        return Span(kind: .comment, end: blockCommentEnd(from: index, nests: features.contains(.nestedBlockComments)))
    }

    private func startsLineComment(at index: Int, unit: UInt16) -> Bool {
        switch unit {
        case Self.dash:
            guard unitAt(index + 1) == Self.dash else { return false }
            guard features.contains(.dashCommentsNeedWhitespace), let next = unitAt(index + 2) else { return true }
            return next <= Self.space
        case Self.hash:
            return features.contains(.hashLineComments)
        case Self.slash:
            return features.contains(.doubleSlashLineComments) && unitAt(index + 1) == Self.slash
        default:
            return false
        }
    }

    private func lineCommentEnd(from index: Int) -> Int {
        let endsAtCarriageReturn = features.contains(.carriageReturnEndsLineComments)
        var cursor = index
        while cursor < units.count {
            let unit = units[cursor]
            if unit == Self.newline || (endsAtCarriageReturn && unit == Self.carriageReturn) {
                return cursor
            }
            cursor += 1
        }
        return cursor
    }

    private func blockCommentEnd(from index: Int, nests: Bool) -> Int {
        var cursor = index + 2
        var depth = 1
        while cursor < units.count {
            if nests, units[cursor] == Self.slash, unitAt(cursor + 1) == Self.star {
                depth += 1
                cursor += 2
                continue
            }
            if units[cursor] == Self.star, unitAt(cursor + 1) == Self.slash {
                depth -= 1
                cursor += 2
                if depth == 0 { return cursor }
                continue
            }
            cursor += 1
        }
        return cursor
    }

    /// The server lexes an executable comment's body as SQL, so a `*/` inside a quoted string does not close it.
    private func executableCommentEnd(from index: Int) -> Int {
        var cursor = index + 2
        while cursor < units.count {
            let unit = units[cursor]
            if unit == Self.star, unitAt(cursor + 1) == Self.slash {
                return cursor + 2
            }
            if unit == Self.singleQuote || unit == Self.doubleQuote || unit == Self.backtick {
                cursor = quotedEnd(from: cursor + 1, quote: unit, backslashEscapes: backslashEscapes(inQuote: unit))
                continue
            }
            cursor += 1
        }
        return cursor
    }

    private func isExecutableCommentOpener(at index: Int) -> Bool {
        var cursor = index + 2
        if unitAt(cursor) == 0x4D || unitAt(cursor) == 0x6D {
            cursor += 1
        }
        return unitAt(cursor) == Self.exclamationMark
    }

    // MARK: - Literals

    private func backslashEscapes(inQuote quote: UInt16) -> Bool {
        switch quote {
        case Self.singleQuote: return features.contains(.backslashEscapesInSingleQuotes)
        case Self.doubleQuote: return features.contains(.backslashEscapesInDoubleQuotes)
        default: return features.contains(.backslashEscapesInBackticks)
        }
    }

    private func quotedEnd(at index: Int, quote: UInt16) -> Int {
        let backslashEscapes = backslashEscapes(inQuote: quote)
        if quote != Self.backtick, features.contains(.tripleQuotedStrings),
           unitAt(index + 1) == quote, unitAt(index + 2) == quote {
            return tripleQuotedEnd(from: index + 3, quote: quote, backslashEscapes: backslashEscapes)
        }
        return quotedEnd(from: index + 1, quote: quote, backslashEscapes: backslashEscapes)
    }

    private func quotedEnd(from start: Int, quote: UInt16, backslashEscapes: Bool) -> Int {
        var cursor = start
        while cursor < units.count {
            let unit = units[cursor]
            if backslashEscapes, unit == Self.backslash, cursor + 1 < units.count {
                cursor += 2
                continue
            }
            if unit == quote {
                if unitAt(cursor + 1) == quote {
                    cursor += 2
                    continue
                }
                return cursor + 1
            }
            cursor += 1
        }
        return cursor
    }

    private func tripleQuotedEnd(from start: Int, quote: UInt16, backslashEscapes: Bool) -> Int {
        var cursor = start
        while cursor < units.count {
            let unit = units[cursor]
            if backslashEscapes, unit == Self.backslash, cursor + 1 < units.count {
                cursor += 2
                continue
            }
            if unit == quote, unitAt(cursor + 1) == quote, unitAt(cursor + 2) == quote {
                return cursor + 3
            }
            cursor += 1
        }
        return cursor
    }

    private func bracketEnd(at index: Int) -> Int {
        let doubledEscapes = features.contains(.doubledClosingBracketEscapes)
        var cursor = index + 1
        while cursor < units.count {
            guard units[cursor] == Self.closeBracket else {
                cursor += 1
                continue
            }
            guard doubledEscapes, unitAt(cursor + 1) == Self.closeBracket else { return cursor + 1 }
            cursor += 2
        }
        return cursor
    }

    private func prefixedLiteralEnd(at index: Int, unit: UInt16) -> Int? {
        guard index == 0 || !isWordUnit(units[index - 1]) else { return nil }
        if features.contains(.escapeStringPrefix), unit == 0x45 || unit == 0x65, unitAt(index + 1) == Self.singleQuote {
            return quotedEnd(from: index + 2, quote: Self.singleQuote, backslashEscapes: true)
        }
        guard features.contains(.alternativeQuoting) else { return nil }
        var cursor = index
        if unit == 0x4E || unit == 0x6E {
            cursor += 1
        }
        guard let prefix = unitAt(cursor), prefix == 0x51 || prefix == 0x71,
              unitAt(cursor + 1) == Self.singleQuote,
              let opener = unitAt(cursor + 2), opener > Self.space
        else {
            return nil
        }
        let closer = alternativeQuoteCloser(for: opener)
        cursor += 3
        while cursor < units.count {
            if units[cursor] == closer, unitAt(cursor + 1) == Self.singleQuote {
                return cursor + 2
            }
            cursor += 1
        }
        return cursor
    }

    private func alternativeQuoteCloser(for opener: UInt16) -> UInt16 {
        switch opener {
        case Self.openBracket: return Self.closeBracket
        case Self.openParen: return Self.closeParen
        case Self.openBrace: return Self.closeBrace
        case Self.lessThan: return Self.greaterThan
        default: return opener
        }
    }

    private func dollarQuotedEnd(at index: Int) -> Int? {
        let tagged = features.contains(.taggedDollarQuotes)
        guard tagged || features.contains(.untaggedDollarQuotes) else { return nil }
        if index > 0, continuesIdentifierBeforeDollar(units[index - 1]) { return nil }
        guard let second = unitAt(index + 1) else { return nil }
        var tagEnd = index + 1
        if second != Self.dollar {
            guard tagged, isTagStart(second) else { return nil }
            tagEnd = index + 2
            while tagEnd < units.count, units[tagEnd] != Self.dollar {
                guard isTagPart(units[tagEnd]) else { return nil }
                tagEnd += 1
            }
            guard tagEnd < units.count else { return nil }
        }
        let delimiter = Array(units[index...tagEnd])
        var cursor = tagEnd + 1
        while cursor + delimiter.count <= units.count {
            if units[cursor] == Self.dollar, Array(units[cursor..<(cursor + delimiter.count)]) == delimiter {
                return cursor + delimiter.count
            }
            cursor += 1
        }
        return units.count
    }

    private func parameterEnd(at index: Int) -> Int? {
        let prefix = units[index]
        guard prefix == Self.dollar || prefix == Self.at || prefix == Self.colon || prefix == Self.hash else {
            return nil
        }
        var cursor = index + 1
        while cursor < units.count, isSQLiteIdentifierUnit(units[cursor]) {
            cursor += 1
        }
        guard cursor > index + 1, unitAt(cursor) == Self.openParen else { return nil }
        cursor += 1
        while cursor < units.count {
            if units[cursor] == Self.closeParen { return cursor + 1 }
            if units[cursor] <= Self.space { return cursor }
            cursor += 1
        }
        return cursor
    }

    // MARK: - Characters

    private func unitAt(_ index: Int) -> UInt16? {
        index < units.count ? units[index] : nil
    }

    private func isASCIIIdentifierPart(_ unit: UInt16) -> Bool {
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || (unit >= 0x30 && unit <= 0x39)
            || unit == 0x5F
    }

    func isWordUnit(_ unit: UInt16) -> Bool {
        unit < 0x80 ? isASCIIIdentifierPart(unit) : !isSeparating(unit)
    }

    private func isSeparating(_ unit: UInt16) -> Bool {
        switch unit {
        case 0xFF10...0xFF19, 0xFF21...0xFF3A, 0xFF3F, 0xFF41...0xFF5A:
            return false
        case 0xFF01...0xFF5E, 0x2018, 0x2019, 0x201C, 0x201D, 0x00A0, 0x2000...0x200A, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    private func continuesIdentifierBeforeDollar(_ unit: UInt16) -> Bool {
        isASCIIIdentifierPart(unit) || unit == Self.dollar || unit >= 0x80
    }

    private func isTagStart(_ unit: UInt16) -> Bool {
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F || unit >= 0x80
    }

    private func isTagPart(_ unit: UInt16) -> Bool {
        isASCIIIdentifierPart(unit) || unit >= 0x80
    }

    private func isSQLiteIdentifierUnit(_ unit: UInt16) -> Bool {
        isASCIIIdentifierPart(unit) || unit == Self.dollar || unit >= 0x80
    }
}
