//
//  MariaDBFieldClassifier.swift
//  MySQLDriverPlugin
//

import Foundation

internal enum MariaDBFieldClassifier {
    private static let bitType: UInt32 = 16
    private static let binaryCharset: UInt32 = 63
    private static let blobOrStringTypes: Set<UInt32> = [249, 250, 251, 252, 253, 254]

    static func isBinary(typeRaw: UInt32, charset: UInt32) -> Bool {
        guard charset == binaryCharset else {
            return false
        }
        return blobOrStringTypes.contains(typeRaw)
    }

    static func isBit(typeRaw: UInt32) -> Bool {
        typeRaw == bitType
    }

    static func bitFieldToString(_ buffer: UnsafeRawBufferPointer) -> String {
        guard !buffer.isEmpty else { return "0" }
        var value: UInt64 = 0
        for byte in buffer {
            value = (value << 8) | UInt64(byte)
        }
        return String(value)
    }

    static func bitFieldToString(_ data: Data) -> String {
        data.withUnsafeBytes { bitFieldToString($0) }
    }
}
