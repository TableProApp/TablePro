import Foundation

enum XMLTextDecoder {
    private static let ampersand: UInt8 = 0x26
    private static let semicolon: UInt8 = 0x3B
    private static let hash: UInt8 = 0x23
    private static let carriageReturn: UInt8 = 0x0D
    private static let lineFeed: UInt8 = 0x0A
    private static let underscore: UInt8 = 0x5F
    private static let lowercaseX: UInt8 = 0x78
    private static let uppercaseX: UInt8 = 0x58
    private static let replacement: Unicode.Scalar = "\u{FFFD}"
    private static let longestEntity = 12

    static func needsDecoding(_ bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>, unescapingOOXML: Bool) -> Bool {
        for index in range {
            let byte = bytes[index]
            if byte == ampersand || byte == carriageReturn || (unescapingOOXML && byte == underscore) {
                return true
            }
        }
        return false
    }

    static func append(
        _ bytes: UnsafeBufferPointer<UInt8>,
        _ range: Range<Int>,
        to output: inout [UInt8],
        unescapingOOXML: Bool
    ) {
        var index = range.lowerBound
        let end = range.upperBound
        while index < end {
            let byte = bytes[index]
            switch byte {
            case ampersand:
                index = appendEntity(bytes, at: index, end: end, to: &output)
            case carriageReturn:
                output.append(lineFeed)
                index += index + 1 < end && bytes[index + 1] == lineFeed ? 2 : 1
            case underscore where unescapingOOXML:
                index = appendOOXMLEscape(bytes, at: index, end: end, to: &output)
            default:
                output.append(byte)
                index += 1
            }
        }
    }

    private static func appendEntity(
        _ bytes: UnsafeBufferPointer<UInt8>,
        at start: Int,
        end: Int,
        to output: inout [UInt8]
    ) -> Int {
        var close = start + 1
        let limit = min(end, start + longestEntity)
        while close < limit, bytes[close] != semicolon { close += 1 }
        guard close < limit, close > start + 1 else {
            output.append(ampersand)
            return start + 1
        }
        let body = (start + 1)..<close
        guard let scalar = entityScalar(bytes, body) else {
            output.append(ampersand)
            return start + 1
        }
        appendScalar(scalar, to: &output)
        return close + 1
    }

    private static func entityScalar(_ bytes: UnsafeBufferPointer<UInt8>, _ body: Range<Int>) -> Unicode.Scalar? {
        if bytes[body.lowerBound] == hash {
            return numericReference(bytes, (body.lowerBound + 1)..<body.upperBound)
        }
        let name = UnsafeBufferPointer(rebasing: bytes[body])
        if name.elementsEqual("lt".utf8) { return "<" }
        if name.elementsEqual("gt".utf8) { return ">" }
        if name.elementsEqual("amp".utf8) { return "&" }
        if name.elementsEqual("quot".utf8) { return "\"" }
        if name.elementsEqual("apos".utf8) { return "'" }
        return nil
    }

    private static func numericReference(_ bytes: UnsafeBufferPointer<UInt8>, _ digits: Range<Int>) -> Unicode.Scalar? {
        guard !digits.isEmpty else { return nil }
        let isHex = bytes[digits.lowerBound] == lowercaseX || bytes[digits.lowerBound] == uppercaseX
        let valueDigits = isHex ? (digits.lowerBound + 1)..<digits.upperBound : digits
        guard !valueDigits.isEmpty else { return nil }
        var value: UInt32 = 0
        for index in valueDigits {
            guard let digit = digitValue(bytes[index], hexadecimal: isHex) else { return nil }
            value = value &* (isHex ? 16 : 10) &+ digit
            guard value <= 0x10_FFFF else { return nil }
        }
        return Unicode.Scalar(value) ?? replacement
    }

    private static func appendOOXMLEscape(
        _ bytes: UnsafeBufferPointer<UInt8>,
        at start: Int,
        end: Int,
        to output: inout [UInt8]
    ) -> Int {
        guard let unit = codeUnit(bytes, at: start, end: end) else {
            output.append(underscore)
            return start + 1
        }
        let next = start + 7
        if UTF16.isLeadSurrogate(unit) {
            if let trail = codeUnit(bytes, at: next, end: end), UTF16.isTrailSurrogate(trail) {
                let combined = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(trail) - 0xDC00)
                appendScalar(Unicode.Scalar(combined) ?? replacement, to: &output)
                return next + 7
            }
            appendScalar(replacement, to: &output)
            return next
        }
        appendScalar(Unicode.Scalar(unit) ?? replacement, to: &output)
        return next
    }

    private static func codeUnit(_ bytes: UnsafeBufferPointer<UInt8>, at start: Int, end: Int) -> UInt16? {
        guard start + 7 <= end, bytes[start] == underscore, bytes[start + 1] == lowercaseX,
              bytes[start + 6] == underscore else { return nil }
        var value: UInt32 = 0
        for index in (start + 2)..<(start + 6) {
            guard let digit = digitValue(bytes[index], hexadecimal: true) else { return nil }
            value = value * 16 + digit
        }
        return UInt16(value)
    }

    private static func digitValue(_ byte: UInt8, hexadecimal: Bool) -> UInt32? {
        switch byte {
        case 0x30...0x39:
            return UInt32(byte - 0x30)
        case 0x41...0x46 where hexadecimal:
            return UInt32(byte - 0x41 + 10)
        case 0x61...0x66 where hexadecimal:
            return UInt32(byte - 0x61 + 10)
        default:
            return nil
        }
    }

    private static func appendScalar(_ scalar: Unicode.Scalar, to output: inout [UInt8]) {
        UTF8.encode(scalar) { output.append($0) }
    }
}
