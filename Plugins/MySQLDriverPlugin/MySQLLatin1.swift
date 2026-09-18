//
//  MySQLLatin1.swift
//  MySQLDriverPlugin
//

import Foundation

nonisolated internal enum MySQLLatin1 {
    private static let windowsRangeScalars: [UInt32] = [
        0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
        0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178
    ]

    private static let windowsRange = 0x80...0x9F

    static let scalarsByByte: [Unicode.Scalar] = (0...255).map { byte in
        guard windowsRange.contains(byte),
              let scalar = Unicode.Scalar(windowsRangeScalars[byte - windowsRange.lowerBound]) else {
            return Unicode.Scalar(UInt8(byte))
        }
        return scalar
    }

    private static let bytesByScalar: [UInt32: UInt8] = Dictionary(
        uniqueKeysWithValues: scalarsByByte.enumerated().map { ($0.element.value, UInt8($0.offset)) }
    )

    static func decode(_ bytes: UnsafeRawBufferPointer) -> String {
        guard bytes.contains(where: { $0 >= 0x80 }) else {
            return MySQLCharacterSet.decodeUTF8ReplacingInvalid(bytes)
        }
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(bytes.count)
        for byte in bytes {
            scalars.append(scalarsByByte[Int(byte)])
        }
        return String(scalars)
    }

    static func decode(_ bytes: [UInt8]) -> String {
        bytes.withUnsafeBytes { decode($0) }
    }

    static func bytes(representing text: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            guard let byte = bytesByScalar[scalar.value] else { return nil }
            bytes.append(byte)
        }
        return bytes
    }

    static func repairingDoubleEncodedUTF8(_ text: String) -> String {
        guard text.utf8.contains(where: { $0 >= 0x80 }) else { return text }
        guard let original = bytes(representing: text),
              let repaired = String(bytes: original, encoding: .utf8) else {
            return text
        }
        return repaired
    }
}
