//
//  HugeIntFormatter.swift
//  TableProPluginKit
//

import Foundation

public enum HugeIntFormatter {
    public static func format(upper: Int64, lower: UInt64) -> String {
        let upperBits = UInt64(bitPattern: upper)
        if upper >= 0 {
            return formatUnsigned(upper: upperBits, lower: lower)
        }
        let invLower = ~lower
        let invUpper = ~upperBits
        let (sumLower, carry) = invLower.addingReportingOverflow(1)
        let sumUpper = invUpper &+ (carry ? 1 : 0)
        return "-\(formatUnsigned(upper: sumUpper, lower: sumLower))"
    }

    public static func formatUnsigned(upper: UInt64, lower: UInt64) -> String {
        if upper == 0 {
            return String(lower)
        }
        var limbs: [UInt32] = [
            UInt32(upper >> 32),
            UInt32(upper & 0xFFFF_FFFF),
            UInt32(lower >> 32),
            UInt32(lower & 0xFFFF_FFFF)
        ]
        let divisor: UInt64 = 1_000_000_000
        var chunks: [UInt32] = []
        while limbs.contains(where: { $0 != 0 }) {
            var rem: UInt64 = 0
            for i in 0..<limbs.count {
                let acc = (rem << 32) | UInt64(limbs[i])
                limbs[i] = UInt32(acc / divisor)
                rem = acc % divisor
            }
            chunks.append(UInt32(rem))
        }
        var result = String(chunks.last ?? 0)
        for i in stride(from: chunks.count - 2, through: 0, by: -1) {
            result += String(format: "%09u", chunks[i])
        }
        return result
    }
}
