//
//  CassandraCellText.swift
//  CassandraDriverPlugin
//

import Foundation

/// The text a cell shows for the CQL types the C driver hands over as raw parts rather than as a string.
enum CassandraCellText {
    private static let nanosecondsPerSecond: Int64 = 1_000_000_000

    /// Cassandra's own spelling of a duration, the form cqlsh prints and CQL accepts back: `1y2mo3d4h5m6s7ms`.
    /// A duration's parts all carry the same sign, so a negative one is the positive spelling with a leading `-`.
    static func durationText(months: Int32, days: Int32, nanoseconds: Int64) -> String {
        let isNegative = months < 0 || days < 0 || nanoseconds < 0
        let months = Int64(months).magnitude
        let days = Int64(days).magnitude
        var remaining = nanoseconds.magnitude
        var parts: [(UInt64, String)] = [(months / 12, "y"), (months % 12, "mo"), (days, "d")]
        for (size, unit) in [(3_600 * UInt64(nanosecondsPerSecond), "h"), (60 * UInt64(nanosecondsPerSecond), "m"),
                             (UInt64(nanosecondsPerSecond), "s"), (1_000_000, "ms"), (1_000, "us"), (1, "ns")] {
            parts.append((remaining / size, unit))
            remaining %= size
        }
        let text = parts.filter { $0.0 > 0 }.map { "\($0.0)\($0.1)" }.joined()
        guard !text.isEmpty else { return "0s" }
        return isNegative ? "-" + text : text
    }

    /// A `vector<float, n>` arrives as a custom type whose class name carries the element type, with the values
    /// packed as big-endian 32-bit floats. Any other custom value is shown as its bytes.
    static func customText(className: String?, bytes: Data) -> String {
        guard let className, isFloatVector(className), bytes.count.isMultiple(of: 4) else {
            return hex(bytes)
        }
        let values = stride(from: 0, to: bytes.count, by: 4).map { offset -> String in
            let bits = bytes[bytes.startIndex + offset..<bytes.startIndex + offset + 4]
                .reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            return String(Float(bitPattern: bits))
        }
        return "[" + values.joined(separator: ", ") + "]"
    }

    static func hex(_ bytes: Data) -> String {
        "0x" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func isFloatVector(_ className: String) -> Bool {
        guard let open = className.range(of: "VectorType(") else { return false }
        let elementType = className[open.upperBound...].prefix { $0 != "," }
        return elementType.trimmingCharacters(in: .whitespaces).hasSuffix("FloatType")
    }
}
