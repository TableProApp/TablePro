//
//  CassandraVarintTests.swift
//  TableProCassandraCoreTests
//

import Foundation
import TableProCassandraCore
import Testing

struct CassandraVarintTests {
    @Test("Known varints read as their decimal text", arguments: [
        ([UInt8](), "0"),
        ([0x00], "0"),
        ([0x7F], "127"),
        ([0x80], "-128"),
        ([0xFF], "-1"),
        ([0x01, 0x00], "256"),
        ([0x3B, 0x9A, 0xCA, 0x00], "1000000000"),
        ([0x0D, 0xE0, 0xB6, 0xB3, 0xA7, 0x64, 0x00, 0x00], "1000000000000000000"),
        ([0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], "18446744073709551616"),
        ([0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], "-18446744073709551616"),
    ])
    func knownValues(bytes: [UInt8], expected: String) {
        #expect(CassandraVarint.decimalString(fromTwosComplement: Data(bytes)) == expected)
    }

    @Test("Values up to 512 bytes read the same as long division by ten, both signs")
    func matchesLongDivision() throws {
        var generator = SplitMix64(seed: 0x5EED)
        for length in [1, 2, 3, 4, 5, 7, 8, 9, 16, 31, 64, 100, 257, 512] {
            var magnitude = (0..<length).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
            magnitude[0] = max(magnitude[0] & 0x7F, 1)
            let expected = Self.longDivisionDigits(magnitude)
            #expect(CassandraVarint.decimalString(fromTwosComplement: Data(magnitude)) == expected)
            let negative = try #require(CassandraVarint.bytes(fromDecimalInteger: "-" + expected))
            #expect(CassandraVarint.decimalString(fromTwosComplement: negative) == "-" + expected)
        }
    }

    @Test("A varint at the decimal limit still reads as a number")
    func valueAtTheLimit() {
        let bytes = Data([0x01] + [UInt8](repeating: 0x5A, count: CassandraVarint.maximumDecimalBytes - 1))
        let text = CassandraVarint.decimalString(fromTwosComplement: bytes)
        #expect(text.allSatisfy { $0.isASCII && $0.isNumber })
        #expect(text.count > 9_800)
    }

    @Test("A varint past the decimal limit is shown as hex instead of a conversion that grows with its square")
    func longVarintIsHex() {
        let bytes = Data([0x01] + [UInt8](repeating: 0x5A, count: 16 * 1_024 - 1))
        #expect(CassandraVarint.decimalString(fromTwosComplement: bytes) == CassandraCellText.hex(bytes))
    }

    @Test("A decimal whose unscaled integer is past the limit is shown as hex and keeps its scale")
    func longDecimalIsHexWithScale() {
        let unscaled = Data([0x01] + [UInt8](repeating: 0x5A, count: 16 * 1_024 - 1))
        #expect(CassandraVarint.decimalString(unscaled: unscaled, scale: 2) == CassandraCellText.hex(unscaled) + "E-2")
        #expect(CassandraVarint.decimalString(unscaled: unscaled, scale: -3) == CassandraCellText.hex(unscaled) + "E3")
    }

    @Test("Short decimals keep their plain form")
    func shortDecimals() {
        #expect(CassandraVarint.decimalString(unscaled: Data([0x30, 0x39]), scale: 2) == "123.45")
        #expect(CassandraVarint.decimalString(unscaled: Data([0xCF, 0xC7]), scale: 2) == "-123.45")
        #expect(CassandraVarint.decimalString(unscaled: Data([0x05]), scale: -2) == "500")
    }

    @Test("Hex spells every byte in lower case")
    func hexText() {
        #expect(CassandraCellText.hex(Data()) == "0x")
        #expect(CassandraCellText.hex(Data([0x00, 0x0F, 0xA0, 0xFF])) == "0x000fa0ff")
    }

    private static func longDivisionDigits(_ magnitude: [UInt8]) -> String {
        var remaining = Array(magnitude.drop { $0 == 0 })
        guard !remaining.isEmpty else { return "0" }
        var digits: [Character] = []
        while !remaining.isEmpty {
            var remainder = 0
            var quotient: [UInt8] = []
            for byte in remaining {
                let value = remainder << 8 | Int(byte)
                if !(quotient.isEmpty && value / 10 == 0) {
                    quotient.append(UInt8(value / 10))
                }
                remainder = value % 10
            }
            digits.append(Character(String(remainder)))
            remaining = quotient
        }
        return String(digits.reversed())
    }
}

private struct SplitMix64 {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
