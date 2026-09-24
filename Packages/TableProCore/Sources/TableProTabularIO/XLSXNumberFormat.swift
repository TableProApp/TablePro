import Foundation

public enum XLSXNumberFormatCategory: UInt8, Sendable, Equatable {
    case number
    case date
    case time
    case duration
}

public enum XLSXNumberFormat {
    public static func category(ofBuiltInFormat identifier: Int) -> XLSXNumberFormatCategory {
        switch identifier {
        case 14...17, 22, 27...31, 36, 50...58:
            return .date
        case 18...21, 32...35, 45, 47:
            return .time
        case 46:
            return .duration
        default:
            return .number
        }
    }

    public static func category(ofFormatCode code: String) -> XLSXNumberFormatCategory {
        var tokens = TemporalTokens()
        var iterator = code.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            switch scalar {
            case "\"":
                skip(until: "\"", in: &iterator)
            case "[":
                tokens.formUnion(elapsedTokens(readingUntil: "]", in: &iterator))
            case "\\", "_", "*":
                _ = iterator.next()
            default:
                tokens.record(scalar)
            }
        }
        return tokens.category
    }

    private struct TemporalTokens {
        var hasDate = false
        var hasTime = false
        var hasElapsed = false
        var hasMonthOrMinute = false

        mutating func record(_ scalar: Unicode.Scalar) {
            switch scalar {
            case "y", "Y", "d", "D":
                hasDate = true
            case "h", "H", "s", "S":
                hasTime = true
            case "m", "M":
                hasMonthOrMinute = true
            default:
                break
            }
        }

        mutating func formUnion(_ other: TemporalTokens) {
            hasDate = hasDate || other.hasDate
            hasTime = hasTime || other.hasTime
            hasElapsed = hasElapsed || other.hasElapsed
            hasMonthOrMinute = hasMonthOrMinute || other.hasMonthOrMinute
        }

        var category: XLSXNumberFormatCategory {
            if hasDate { return .date }
            if hasElapsed { return .duration }
            if hasTime { return .time }
            return hasMonthOrMinute ? .date : .number
        }
    }

    private static func skip(until terminator: Unicode.Scalar, in iterator: inout String.UnicodeScalarView.Iterator) {
        while let scalar = iterator.next(), scalar != terminator {}
    }

    private static func elapsedTokens(
        readingUntil terminator: Unicode.Scalar,
        in iterator: inout String.UnicodeScalarView.Iterator
    ) -> TemporalTokens {
        var content: [Unicode.Scalar] = []
        while let scalar = iterator.next(), scalar != terminator {
            content.append(scalar)
        }
        let elapsed: Set<Unicode.Scalar> = ["h", "H", "m", "M", "s", "S"]
        guard !content.isEmpty, content.allSatisfy({ elapsed.contains($0) }) else { return TemporalTokens() }
        var tokens = TemporalTokens()
        tokens.hasElapsed = true
        return tokens
    }
}

public struct XLSXStyleSheet: Sendable, Equatable {
    public let categories: [XLSXNumberFormatCategory]

    public init(categories: [XLSXNumberFormatCategory]) {
        self.categories = categories
    }

    public static let empty = XLSXStyleSheet(categories: [])

    public func category(ofStyle index: Int) -> XLSXNumberFormatCategory {
        guard index >= 0, index < categories.count else { return .number }
        return categories[index]
    }

    static func parse(_ data: Data) -> XLSXStyleSheet {
        data.withUnsafeBytes { raw in
            parse(raw.bindMemory(to: UInt8.self))
        }
    }

    private static func parse(_ bytes: UnsafeBufferPointer<UInt8>) -> XLSXStyleSheet {
        var scanner = XMLByteScanner(bytes: bytes, isFinal: true)
        var customFormats: [Int: XLSXNumberFormatCategory] = [:]
        var formatIdentifiers: [Int] = []
        var insideFormats = false
        var insideCellFormats = false
        loop: while true {
            switch scanner.next() {
            case .startTag(let name, let attributes, let isSelfClosing):
                if scanner.isNamed(name, "numFmts") {
                    insideFormats = !isSelfClosing
                } else if scanner.isNamed(name, "cellXfs") {
                    insideCellFormats = !isSelfClosing
                } else if insideFormats, scanner.isNamed(name, "numFmt") {
                    guard let identifier = scanner.attribute("numFmtId", in: attributes).flatMap(scanner.integer),
                          let code = scanner.attribute("formatCode", in: attributes) else { continue }
                    customFormats[identifier] = XLSXNumberFormat.category(ofFormatCode: scanner.string(code))
                } else if insideCellFormats, scanner.isNamed(name, "xf") {
                    let identifier = scanner.attribute("numFmtId", in: attributes).flatMap(scanner.integer) ?? 0
                    formatIdentifiers.append(identifier)
                }
            case .endTag(let name):
                if scanner.isNamed(name, "numFmts") { insideFormats = false }
                if scanner.isNamed(name, "cellXfs") { insideCellFormats = false }
            case .text, .characterData, .markup:
                continue
            case .incomplete, .end:
                break loop
            }
        }
        let categories = formatIdentifiers.map { identifier in
            customFormats[identifier] ?? XLSXNumberFormat.category(ofBuiltInFormat: identifier)
        }
        return XLSXStyleSheet(categories: categories)
    }
}
