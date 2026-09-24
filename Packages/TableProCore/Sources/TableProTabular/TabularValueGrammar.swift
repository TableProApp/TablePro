import Foundation
import TableProTabularIO

public enum TabularValueGrammar {
    public static func number(_ bytes: UnsafeBufferPointer<UInt8>) -> Double? {
        let trimmed = trimmingSpaces(bytes)
        guard !trimmed.isEmpty else { return nil }
        guard isASCII(trimmed) else {
            let text = TabularTextCodec.utf8String(bytes).trimmingCharacters(in: .whitespaces)
            return number(text)
        }
        guard isNumericLiteral(trimmed) else { return nil }
        return Double(TabularTextCodec.utf8String(trimmed))
    }

    public static func number(_ text: String) -> Double? {
        var copy = text.trimmingCharacters(in: .whitespaces)
        return copy.withUTF8 { buffer in
            guard !buffer.isEmpty, isASCII(buffer), isNumericLiteral(buffer) else { return nil }
            return Double(TabularTextCodec.utf8String(buffer))
        }
    }

    public static func boolean(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool? {
        let trimmed = trimmingSpaces(bytes)
        guard !trimmed.isEmpty, trimmed.count <= 5 else {
            guard !isASCII(trimmed) else { return nil }
            return boolean(TabularTextCodec.utf8String(bytes))
        }
        var lowered: [UInt8] = []
        lowered.reserveCapacity(trimmed.count)
        for byte in trimmed {
            lowered.append(asciiLowercase(byte))
        }
        switch lowered {
        case Array("true".utf8), Array("1".utf8), Array("yes".utf8), Array("on".utf8), Array("t".utf8):
            return true
        case Array("false".utf8), Array("0".utf8), Array("no".utf8), Array("off".utf8), Array("f".utf8):
            return false
        default:
            return nil
        }
    }

    public static func boolean(_ text: String) -> Bool? {
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "1", "yes", "on", "t":
            return true
        case "false", "0", "no", "off", "f":
            return false
        default:
            return nil
        }
    }

    public static func isNumericLiteral(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        var index = 0
        let count = bytes.count
        guard count > 0 else { return false }
        if bytes[0] == 0x2B || bytes[0] == 0x2D {
            index = 1
        }
        var hasDigit = false
        var hasDot = false
        var hasExponent = false
        while index < count {
            let byte = bytes[index]
            index += 1
            if isDigit(byte) {
                hasDigit = true
                continue
            }
            if byte == 0x2E, !hasDot, !hasExponent {
                hasDot = true
                continue
            }
            if byte == 0x65 || byte == 0x45, hasDigit, !hasExponent {
                hasExponent = true
                hasDigit = false
                guard index < count else { return false }
                let next = bytes[index]
                index += 1
                if isDigit(next) {
                    hasDigit = true
                    continue
                }
                if next == 0x2B || next == 0x2D {
                    continue
                }
                return false
            }
            return false
        }
        return hasDigit
    }

    @inline(__always)
    public static func isDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }

    @inline(__always)
    public static func asciiLowercase(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte
    }

    public static func isASCII(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        for byte in bytes where byte >= 0x80 {
            return false
        }
        return true
    }

    public static func trimmingSpaces(_ bytes: UnsafeBufferPointer<UInt8>) -> UnsafeBufferPointer<UInt8> {
        var start = 0
        var end = bytes.count
        while start < end, bytes[start] == 0x20 || bytes[start] == 0x09 {
            start += 1
        }
        while end > start, bytes[end - 1] == 0x20 || bytes[end - 1] == 0x09 {
            end -= 1
        }
        return UnsafeBufferPointer(rebasing: bytes[start..<end])
    }
}
