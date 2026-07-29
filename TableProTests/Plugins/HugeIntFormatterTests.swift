//
//  HugeIntFormatterTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("HugeIntFormatter")
struct HugeIntFormatterTests {
    @Test("Zero")
    func zero() {
        #expect(HugeIntFormatter.format(upper: 0, lower: 0) == "0")
        #expect(HugeIntFormatter.formatUnsigned(upper: 0, lower: 0) == "0")
    }

    @Test("Small positive fits in lower limb")
    func smallPositive() {
        #expect(HugeIntFormatter.format(upper: 0, lower: 42) == "42")
        #expect(HugeIntFormatter.format(upper: 0, lower: UInt64.max) == "18446744073709551615")
    }

    @Test("Negative one")
    func negativeOne() {
        #expect(HugeIntFormatter.format(upper: -1, lower: UInt64.max) == "-1")
    }

    @Test("Small negative")
    func smallNegative() {
        #expect(HugeIntFormatter.format(upper: -1, lower: UInt64.max - 41) == "-42")
    }

    @Test("Int128 max")
    func int128Max() {
        #expect(HugeIntFormatter.format(upper: Int64.max, lower: UInt64.max)
            == "170141183460469231731687303715884105727")
    }

    @Test("Int128 min")
    func int128Min() {
        #expect(HugeIntFormatter.format(upper: Int64.min, lower: 0)
            == "-170141183460469231731687303715884105728")
    }

    @Test("Just above Int64 range")
    func justAboveInt64Max() {
        #expect(HugeIntFormatter.format(upper: 0, lower: UInt64(Int64.max) + 1)
            == "9223372036854775808")
    }

    @Test("Just below Int64 range")
    func justBelowInt64Min() {
        #expect(HugeIntFormatter.format(upper: -1, lower: UInt64(bitPattern: Int64.min) - 1)
            == "-9223372036854775809")
    }

    @Test("UInt128 max preserves full precision")
    func uint128Max() {
        #expect(HugeIntFormatter.formatUnsigned(upper: UInt64.max, lower: UInt64.max)
            == "340282366920938463463374607431768211455")
    }

    @Test("Value crossing 2^64 boundary")
    func crossing2to64() {
        #expect(HugeIntFormatter.formatUnsigned(upper: 1, lower: 0) == "18446744073709551616")
        #expect(HugeIntFormatter.formatUnsigned(upper: 1, lower: 1) == "18446744073709551617")
    }

    @Test("Negative crossing 2^64 boundary")
    func negativeCrossing2to64() {
        #expect(HugeIntFormatter.format(upper: -1, lower: 0) == "-18446744073709551616")
        #expect(HugeIntFormatter.format(upper: -2, lower: 0) == "-36893488147419103232")
    }

    @Test("Result has no leading zeros on most significant chunk")
    func noLeadingZeros() {
        let result = HugeIntFormatter.formatUnsigned(upper: 0, lower: 1)
        #expect(result == "1")
        #expect(!result.hasPrefix("0"))
    }

    @Test("Chunks past the first are zero-padded to 9 digits")
    func internalChunksPadded() {
        let result = HugeIntFormatter.formatUnsigned(upper: 1, lower: 0)
        #expect(result == "18446744073709551616")
        #expect(result.count == 20)
    }
}
