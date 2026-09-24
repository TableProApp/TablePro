import Foundation

enum XLSXStoredCell {
    static let empty: UInt8 = 0
    static let sharedString: UInt8 = 1
    static let inlineText: UInt8 = 2
    static let numberText: UInt8 = 3
    static let booleanFalse: UInt8 = 4
    static let booleanTrue: UInt8 = 5
    static let errorText: UInt8 = 6
    static let dateText: UInt8 = 7
    static let dateSerial: UInt8 = 8
    static let timeSerial: UInt8 = 9
    static let durationSerial: UInt8 = 10
    static let decimalBase: UInt8 = 32
    static let largestDecimalScale = 18

    static func isDecimal(_ kind: UInt8) -> Bool {
        kind >= decimalBase && kind <= decimalBase + UInt8(largestDecimalScale)
    }

    static func tabularKind(of kind: UInt8) -> TabularCellKind {
        if isDecimal(kind) { return .number }
        switch kind {
        case numberText: return .number
        case booleanFalse, booleanTrue: return .boolean
        case errorText: return .error
        case dateText, dateSerial, timeSerial, durationSerial: return .date
        default: return .text
        }
    }

    static func usesArena(_ kind: UInt8) -> Bool {
        kind == inlineText || kind == numberText || kind == errorText || kind == dateText
    }
}

enum XLSXDecimal {
    private static let powersOfTen: [Double] = (0...XLSXStoredCell.largestDecimalScale).map { pow(10, Double($0)) }

    static func parse(_ bytes: UnsafeBufferPointer<UInt8>) -> (mantissa: Int64, scale: Int)? {
        var index = 0
        let count = bytes.count
        guard count > 0 else { return nil }
        let isNegative = bytes[0] == 0x2D
        if isNegative { index = 1 }
        let integerStart = index
        var mantissa: Int64 = 0
        var digits = 0
        while index < count, isDigit(bytes[index]) {
            mantissa = mantissa * 10 + Int64(bytes[index] - 0x30)
            digits += 1
            guard digits <= XLSXStoredCell.largestDecimalScale else { return nil }
            index += 1
        }
        let integerDigits = index - integerStart
        guard integerDigits > 0, integerDigits == 1 || bytes[integerStart] != 0x30 else { return nil }
        var scale = 0
        if index < count, bytes[index] == 0x2E {
            index += 1
            while index < count, isDigit(bytes[index]) {
                mantissa = mantissa * 10 + Int64(bytes[index] - 0x30)
                digits += 1
                scale += 1
                guard digits <= XLSXStoredCell.largestDecimalScale else { return nil }
                index += 1
            }
            guard scale > 0 else { return nil }
        }
        guard index == count, !(isNegative && mantissa == 0) else { return nil }
        return (isNegative ? -mantissa : mantissa, scale)
    }

    static func doubleValue(mantissa: Int64, scale: Int) -> Double {
        Double(mantissa) / powersOfTen[scale]
    }

    static func doubleValue(of bytes: UnsafeBufferPointer<UInt8>) -> Double? {
        if let decimal = parse(bytes) {
            return doubleValue(mantissa: decimal.mantissa, scale: decimal.scale)
        }
        guard TabularNumberGrammar.shape(of: bytes) != nil else { return nil }
        return Double(TabularTextCodec.string(from: bytes, encoding: .utf8))
    }

    static func append(mantissa: Int64, scale: Int, to output: inout [UInt8]) {
        if mantissa < 0 { output.append(0x2D) }
        let magnitude = mantissa.magnitude
        var length = 1
        var probe = magnitude
        while probe >= 10 {
            probe /= 10
            length += 1
        }
        let width = max(length, scale + 1)
        let start = output.count
        output.append(contentsOf: repeatElement(0x30, count: width))
        var remaining = magnitude
        var index = output.count - 1
        while remaining > 0 {
            output[index] = UInt8(0x30 + remaining % 10)
            remaining /= 10
            index -= 1
        }
        guard scale > 0 else { return }
        output.insert(0x2E, at: start + width - scale)
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }
}
