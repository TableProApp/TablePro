import Foundation

public enum TabularNumberGrammar {
    public struct Shape: Equatable, Sendable {
        public let isInteger: Bool
        public let hasRedundantLeadingZero: Bool
    }

    public static func shape(of bytes: UnsafeBufferPointer<UInt8>) -> Shape? {
        var index = 0
        let count = bytes.count
        guard count > 0 else { return nil }
        if bytes[index] == 0x2B || bytes[index] == 0x2D {
            index += 1
        }
        let integerStart = index
        while index < count, isDigit(bytes[index]) {
            index += 1
        }
        let integerDigits = index - integerStart
        var fractionDigits = 0
        var isInteger = true
        if index < count, bytes[index] == 0x2E {
            isInteger = false
            index += 1
            let fractionStart = index
            while index < count, isDigit(bytes[index]) {
                index += 1
            }
            fractionDigits = index - fractionStart
        }
        guard integerDigits + fractionDigits > 0 else { return nil }
        if index < count, bytes[index] == 0x65 || bytes[index] == 0x45 {
            isInteger = false
            index += 1
            if index < count, bytes[index] == 0x2B || bytes[index] == 0x2D {
                index += 1
            }
            let exponentStart = index
            while index < count, isDigit(bytes[index]) {
                index += 1
            }
            guard index > exponentStart else { return nil }
        }
        guard index == count else { return nil }
        let leadingZero = integerDigits > 1 && bytes[integerStart] == 0x30
        return Shape(isInteger: isInteger, hasRedundantLeadingZero: leadingZero)
    }

    public static func shape(of text: String) -> Shape? {
        var copy = text
        return copy.withUTF8 { shape(of: $0) }
    }

    public static func doubleValue(of bytes: UnsafeBufferPointer<UInt8>) -> Double? {
        guard shape(of: bytes) != nil else { return nil }
        return Double(String(decoding: bytes, as: UTF8.self))
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }
}
