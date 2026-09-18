import Foundation

internal struct SQLPlaceholderScanner {
    let units: [UInt16]
    private let lexicon: SQLPlaceholderLexicon
    private var index = 0

    init(units: [UInt16], lexicon: SQLPlaceholderLexicon) {
        self.units = units
        self.lexicon = lexicon
    }

    mutating func placeholderOffsets() -> [Int] {
        var offsets: [Int] = []
        index = 0
        while index < units.count {
            if units[index] == Unit.question {
                offsets.append(index)
                index += 1
                continue
            }
            skipToken()
        }
        return offsets
    }

    private mutating func skipToken() {
        switch units[index] {
        case Unit.dash where unit(at: index + 1) == Unit.dash:
            skipLineComment()
        case Unit.slash where unit(at: index + 1) == Unit.star:
            skipBlockComment()
        case Unit.hash where lexicon == .googleSQL:
            skipLineComment()
        case Unit.singleQuote:
            skipSingleQuoted()
        case Unit.doubleQuote:
            skipDoubleQuoted()
        case Unit.backtick where lexicon == .googleSQL:
            skipEscapedQuoted(delimiter: Unit.backtick, from: index + 1)
        case Unit.dollar where lexicon == .postgreSQL:
            skipDollarQuotedOrSign()
        default:
            skipWordOrUnit()
        }
    }

    private func unit(at position: Int) -> UInt16? {
        position < units.count ? units[position] : nil
    }

    private mutating func skipLineComment() {
        while index < units.count, units[index] != Unit.lineFeed, units[index] != Unit.carriageReturn {
            index += 1
        }
    }

    private mutating func skipBlockComment() {
        index += 2
        var depth = 1
        while index < units.count {
            if units[index] == Unit.star, unit(at: index + 1) == Unit.slash {
                index += 2
                depth -= 1
                if depth == 0 { return }
                continue
            }
            if lexicon == .postgreSQL, units[index] == Unit.slash, unit(at: index + 1) == Unit.star {
                index += 2
                depth += 1
                continue
            }
            index += 1
        }
    }

    private mutating func skipSingleQuoted() {
        switch lexicon {
        case .googleSQL:
            skipGoogleSQLQuoted(delimiter: Unit.singleQuote)
        case .postgreSQL:
            skipDoubledQuoted(delimiter: Unit.singleQuote, from: index + 1)
        }
    }

    private mutating func skipDoubleQuoted() {
        switch lexicon {
        case .googleSQL:
            skipGoogleSQLQuoted(delimiter: Unit.doubleQuote)
        case .postgreSQL:
            skipDoubledQuoted(delimiter: Unit.doubleQuote, from: index + 1)
        }
    }

    private mutating func skipGoogleSQLQuoted(delimiter: UInt16) {
        guard unit(at: index + 1) == delimiter, unit(at: index + 2) == delimiter else {
            skipEscapedQuoted(delimiter: delimiter, from: index + 1)
            return
        }
        skipTripleQuoted(delimiter: delimiter, from: index + 3)
    }

    private mutating func skipTripleQuoted(delimiter: UInt16, from start: Int) {
        index = start
        while index < units.count {
            if units[index] == Unit.backslash {
                index += 2
                continue
            }
            if units[index] == delimiter, unit(at: index + 1) == delimiter, unit(at: index + 2) == delimiter {
                index += 3
                return
            }
            index += 1
        }
    }

    private mutating func skipEscapedQuoted(delimiter: UInt16, from start: Int) {
        index = start
        while index < units.count {
            if units[index] == Unit.backslash {
                index += 2
                continue
            }
            index += 1
            if units[index - 1] == delimiter { return }
        }
    }

    private mutating func skipDoubledQuoted(delimiter: UInt16, from start: Int) {
        index = start
        while index < units.count {
            guard units[index] == delimiter else {
                index += 1
                continue
            }
            if unit(at: index + 1) == delimiter {
                index += 2
                continue
            }
            index += 1
            return
        }
    }

    private mutating func skipEscapeString(from start: Int) {
        index = start
        while index < units.count {
            if units[index] == Unit.backslash {
                index += 2
                continue
            }
            guard units[index] == Unit.singleQuote else {
                index += 1
                continue
            }
            if unit(at: index + 1) == Unit.singleQuote {
                index += 2
                continue
            }
            index += 1
            return
        }
    }

    private mutating func skipDollarQuotedOrSign() {
        guard let delimiter = dollarDelimiter(at: index) else {
            index += 1
            return
        }
        let bodyStart = index + delimiter.count
        guard let closing = firstOccurrence(of: delimiter, from: bodyStart) else {
            index = units.count
            return
        }
        index = closing + delimiter.count
    }

    private func dollarDelimiter(at start: Int) -> ArraySlice<UInt16>? {
        var cursor = start + 1
        while cursor < units.count, isDollarTagUnit(units[cursor], isFirst: cursor == start + 1) {
            cursor += 1
        }
        guard unit(at: cursor) == Unit.dollar else { return nil }
        return units[start...cursor]
    }

    private func isDollarTagUnit(_ unit: UInt16, isFirst: Bool) -> Bool {
        if Unit.isLetter(unit) || unit == Unit.underscore || unit >= 0x80 { return true }
        return !isFirst && Unit.isDigit(unit)
    }

    private func firstOccurrence(of delimiter: ArraySlice<UInt16>, from start: Int) -> Int? {
        guard let first = delimiter.first, units.count >= delimiter.count else { return nil }
        let lastStart = units.count - delimiter.count
        var cursor = start
        while cursor <= lastStart {
            if units[cursor] == first, units[cursor..<(cursor + delimiter.count)].elementsEqual(delimiter) {
                return cursor
            }
            cursor += 1
        }
        return nil
    }

    private mutating func skipWordOrUnit() {
        guard isWordUnit(units[index]) else {
            index += 1
            return
        }
        let start = index
        while index < units.count, isWordUnit(units[index]) {
            index += 1
        }
        guard lexicon == .postgreSQL,
              index - start == 1,
              units[start] == Unit.upperE || units[start] == Unit.lowerE,
              unit(at: index) == Unit.singleQuote
        else {
            return
        }
        skipEscapeString(from: index + 1)
    }

    private func isWordUnit(_ unit: UInt16) -> Bool {
        if Unit.isLetter(unit) || Unit.isDigit(unit) || unit == Unit.underscore || unit >= 0x80 { return true }
        return lexicon == .postgreSQL && unit == Unit.dollar
    }
}

private enum Unit {
    static let question = UInt16(UInt8(ascii: "?"))
    static let dash = UInt16(UInt8(ascii: "-"))
    static let slash = UInt16(UInt8(ascii: "/"))
    static let star = UInt16(UInt8(ascii: "*"))
    static let hash = UInt16(UInt8(ascii: "#"))
    static let singleQuote = UInt16(UInt8(ascii: "'"))
    static let doubleQuote = UInt16(UInt8(ascii: "\""))
    static let backtick = UInt16(UInt8(ascii: "`"))
    static let backslash = UInt16(UInt8(ascii: "\\"))
    static let dollar = UInt16(UInt8(ascii: "$"))
    static let underscore = UInt16(UInt8(ascii: "_"))
    static let lineFeed = UInt16(UInt8(ascii: "\n"))
    static let carriageReturn = UInt16(UInt8(ascii: "\r"))
    static let upperE = UInt16(UInt8(ascii: "E"))
    static let lowerE = UInt16(UInt8(ascii: "e"))

    static func isLetter(_ unit: UInt16) -> Bool {
        (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
    }

    static func isDigit(_ unit: UInt16) -> Bool {
        (0x30...0x39).contains(unit)
    }
}
