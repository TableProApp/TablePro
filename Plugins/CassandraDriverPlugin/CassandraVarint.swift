//
//  CassandraVarint.swift
//  CassandraDriverPlugin
//

import Foundation

/// CQL's `varint` is a big-endian two's complement integer of any length, and `decimal` is that integer unscaled
/// with a 32-bit scale beside it. The C driver hands both over as raw bytes, so reading and writing them as numbers
/// is done here.
enum CassandraVarint {
    static func decimalString(fromTwosComplement bytes: Data) -> String {
        guard let first = bytes.first else { return "0" }
        let isNegative = first & 0x80 != 0
        var magnitude = [UInt8](bytes)
        if isNegative {
            magnitude = negated(magnitude)
        }
        let digits = decimalDigits(ofMagnitude: magnitude)
        return isNegative ? "-" + digits : digits
    }

    /// A scale the plain form would pad with more zeros than this is written with an exponent instead. The wire
    /// scale is any 32-bit value, and expanding one near its limits would allocate billions of characters.
    static let maximumExpandedZeros = 64

    static func decimalString(unscaled: Data, scale: Int32) -> String {
        let integer = decimalString(fromTwosComplement: unscaled)
        let isNegative = integer.hasPrefix("-")
        var digits = isNegative ? String(integer.dropFirst()) : integer
        let fractionLength = Int(scale)
        guard fractionLength >= -maximumExpandedZeros, fractionLength <= digits.count + maximumExpandedZeros else {
            return integer + "E" + String(-fractionLength)
        }
        if fractionLength <= 0 {
            if digits != "0" {
                digits += String(repeating: "0", count: -fractionLength)
            }
            return isNegative ? "-" + digits : digits
        }
        if digits.count <= fractionLength {
            digits = String(repeating: "0", count: fractionLength - digits.count + 1) + digits
        }
        let split = digits.index(digits.endIndex, offsetBy: -fractionLength)
        let rendered = digits[..<split] + "." + digits[split...]
        return isNegative ? "-" + rendered : String(rendered)
    }

    static func bytes(fromDecimalInteger text: String) -> Data? {
        var body = Substring(text)
        var isNegative = false
        if body.first == "-" || body.first == "+" {
            isNegative = body.first == "-"
            body = body.dropFirst()
        }
        guard !body.isEmpty, body.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }

        var magnitude: [UInt8] = [0]
        for character in body {
            guard let digit = character.wholeNumberValue else { return nil }
            var carry = digit
            for index in stride(from: magnitude.count - 1, through: 0, by: -1) {
                let product = Int(magnitude[index]) * 10 + carry
                magnitude[index] = UInt8(product & 0xFF)
                carry = product >> 8
            }
            while carry > 0 {
                magnitude.insert(UInt8(carry & 0xFF), at: 0)
                carry >>= 8
            }
        }
        return Data(twosComplement(magnitude: trimmedMagnitude(magnitude), isNegative: isNegative))
    }

    static func decimal(fromText text: String) -> (unscaled: Data, scale: Int32)? {
        var mantissa = Substring(text)
        var exponent = 0
        if let marker = mantissa.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            guard let parsed = Int(mantissa[mantissa.index(after: marker)...]) else { return nil }
            exponent = parsed
            mantissa = mantissa[..<marker]
        }
        var sign = ""
        if mantissa.first == "-" || mantissa.first == "+" {
            sign = mantissa.first == "-" ? "-" : ""
            mantissa = mantissa.dropFirst()
        }
        let parts = mantissa.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let integerPart = parts[0]
        let fractionPart = parts.count == 2 ? parts[1] : ""
        guard !(integerPart.isEmpty && fractionPart.isEmpty) else { return nil }
        let (scale, overflowed) = fractionPart.count.subtractingReportingOverflow(exponent)
        guard !overflowed, let scale32 = Int32(exactly: scale),
              let unscaled = bytes(fromDecimalInteger: sign + (integerPart.isEmpty ? "0" : integerPart) + fractionPart)
        else { return nil }
        return (unscaled, scale32)
    }

    private static func decimalDigits(ofMagnitude magnitude: [UInt8]) -> String {
        var remaining = trimmedMagnitude(magnitude)
        guard remaining != [0] else { return "0" }
        var digits: [Character] = []
        while !(remaining.count == 1 && remaining[0] == 0) {
            var remainder = 0
            var quotient: [UInt8] = []
            for byte in remaining {
                let value = remainder << 8 | Int(byte)
                let digit = value / 10
                remainder = value % 10
                if !(quotient.isEmpty && digit == 0) {
                    quotient.append(UInt8(digit))
                }
            }
            digits.append(Character(String(remainder)))
            remaining = quotient.isEmpty ? [0] : quotient
        }
        return String(digits.reversed())
    }

    private static func trimmedMagnitude(_ magnitude: [UInt8]) -> [UInt8] {
        let trimmed = magnitude.drop { $0 == 0 }
        return trimmed.isEmpty ? [0] : Array(trimmed)
    }

    private static func twosComplement(magnitude: [UInt8], isNegative: Bool) -> [UInt8] {
        var bytes = magnitude
        if bytes[0] & 0x80 != 0 {
            bytes.insert(0, at: 0)
        }
        guard isNegative, bytes != [0] else { return bytes }
        bytes = negated(bytes)
        while bytes.count > 1, bytes[0] == 0xFF, bytes[1] & 0x80 != 0 {
            bytes.removeFirst()
        }
        return bytes
    }

    private static func negated(_ bytes: [UInt8]) -> [UInt8] {
        var result = bytes.map { ~$0 }
        var index = result.count - 1
        while index >= 0 {
            let (sum, overflow) = result[index].addingReportingOverflow(1)
            result[index] = sum
            if !overflow { break }
            index -= 1
        }
        return result
    }
}
