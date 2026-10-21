//
//  SeededGenerator.swift
//  TablePro
//

import Foundation

// SplitMix64 with its own bounded draws: the standard library's `random(in:using:)` may change its algorithm between
// releases, and a seed has to give the same rows in every version of the app.
internal struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    internal init(seed: UInt64) {
        state = seed
    }

    // Each column draws from its own stream, so changing one column's generator leaves every other column's values.
    internal init(seed: UInt64, stream: String) {
        state = seed ^ Self.fnv1a(stream)
    }

    internal mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }

    internal mutating func unit() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }

    internal mutating func index(below count: Int) -> Int {
        guard count > 1 else { return 0 }
        return Int(bounded(UInt64(count)))
    }

    internal mutating func integer(in range: ClosedRange<Int64>) -> Int64 {
        let span = UInt64(bitPattern: range.upperBound &- range.lowerBound)
        guard span < UInt64.max else { return Int64(bitPattern: next()) }
        return range.lowerBound &+ Int64(bitPattern: bounded(span + 1))
    }

    internal mutating func chance(_ ratio: Double) -> Bool {
        guard ratio > 0 else { return false }
        guard ratio < 1 else { return true }
        return unit() < ratio
    }

    // Lemire's multiply-shift with rejection, so every value in the range is equally likely.
    private mutating func bounded(_ upper: UInt64) -> UInt64 {
        var product = next().multipliedFullWidth(by: upper)
        if product.low < upper {
            let threshold = (0 &- upper) % upper
            while product.low < threshold {
                product = next().multipliedFullWidth(by: upper)
            }
        }
        return product.high
    }

    private static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return hash
    }
}
