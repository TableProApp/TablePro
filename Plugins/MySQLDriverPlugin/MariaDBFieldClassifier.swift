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
        if typeRaw == bitType {
            return true
        }
        guard charset == binaryCharset else {
            return false
        }
        return blobOrStringTypes.contains(typeRaw)
    }
}
