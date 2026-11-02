//
//  CassandraVarint.swift
//  TableProCassandraCore
//

import Foundation

// CQL's `varint` is a big-endian two's complement integer of any length, and `decimal` is that integer unscaled
// with a 32-bit scale beside it. The C driver hands both over as raw bytes, so reading and writing them as numbers
// is done here.
public enum CassandraVarint {
    // Each pass over the number yields nine digits, so the cost grows with the square of its length and a longer
    // value is shown as hex. 4 KiB is about 9,900 digits, near the 10,000 characters the grid shows of a cell.
    public static let maximumDecimalBytes = 4_096

    public static func decimalString(fromTwosComplement bytes: Data) -> String {
        guard let first = bytes.first else { return "0" }
        guard bytes.count <= maximumDecimalBytes else { return CassandraCellText.hex(bytes) }
        let isNegative = first & 0x80 != 0
        var magnitude = [UInt8](bytes)
        if isNegative {
            magnitude = negated(magnitude)
        }
        let digits = decimalDigits(ofMagnitude: magnitude)
        return isNegative ? "-" + digits : digits
    }

    // A scale the plain form would pad with more zeros than this is written with an exponent instead. The wire
    // scale is any 32-bit value, and expanding one near its limits would allocate billions of characters.
    static let maximumExpandedZeros = 64

    public static func decimalString(unscaled: Data, scale: Int32) -> String {
        guard unscaled.count <= maximumDecimalBytes else {
            return CassandraCellText.hex(unscaled) + "E" + String(-Int(scale))
        }
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

    public static func bytes(fromDecimalInteger text: String) -> Data? {
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

    public static func decimal(fromText text: String) -> (unscaled: Data, scale: Int32)? {
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

    private static let chunkDivisor: UInt64 = 1_000_000_000
    private static let chunkDigits = 9

    // Long division of 32-bit limbs by 10^9, nine digits a pass.
    private static func decimalDigits(ofMagnitude magnitude: [UInt8]) -> String {
        var limbs = Self.limbs(ofMagnitude: magnitude)
        guard !limbs.isEmpty else { return "0" }
        var chunks: [UInt64] = []
        while !limbs.isEmpty {
            var remainder: UInt64 = 0
            for index in limbs.indices {
                let value = remainder << 32 | UInt64(limbs[index])
                limbs[index] = UInt32(value / chunkDivisor)
                remainder = value % chunkDivisor
            }
            chunks.append(remainder)
            limbs.removeFirst(limbs.prefix { $0 == 0 }.count)
        }
        var text = String(chunks.removeLast())
        for chunk in chunks.reversed() {
            let digits = String(chunk)
            text += String(repeating: "0", count: chunkDigits - digits.count) + digits
        }
        return text
    }

    private static func limbs(ofMagnitude magnitude: [UInt8]) -> [UInt32] {
        let significant = magnitude.drop { $0 == 0 }
        var limbs: [UInt32] = []
        limbs.reserveCapacity((significant.count + 3) / 4)
        var limb: UInt32 = 0
        var filled = (4 - significant.count % 4) % 4
        for byte in significant {
            limb = limb << 8 | UInt32(byte)
            filled += 1
            if filled == 4 {
                limbs.append(limb)
                limb = 0
                filled = 0
            }
        }
        return limbs
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
