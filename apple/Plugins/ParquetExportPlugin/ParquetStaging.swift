//
//  ParquetStaging.swift
//  ParquetExportPlugin
//

import Foundation

// Kept free of DuckDB so a test bundle can compile it.
enum ParquetStaging {
    static let textType = "VARCHAR"
    static let binaryType = "BLOB"

    static func stagedType(for targetType: String) -> String {
        targetType == binaryType ? binaryType : textType
    }

    static func isCast(_ targetType: String) -> Bool {
        targetType != textType && targetType != binaryType
    }

    // True for a staged value the target type would null or change: TRY_CAST rounds 1.7 into a
    // BIGINT and drops the time of day going into a DATE, and neither is a failed cast.
    static func rejectionPredicate(column: String, type: String) -> String {
        let failed = "TRY_CAST(\(column) AS \(type)) IS NULL"
        let changed: String?
        switch type {
        case "BIGINT", "UBIGINT":
            changed = "TRY_CAST(\(column) AS DOUBLE) IS DISTINCT FROM CAST(TRY_CAST(\(column) AS \(type)) AS DOUBLE)"
        case "DATE":
            changed = "TRY_CAST(\(column) AS TIMESTAMP) IS DISTINCT FROM CAST(TRY_CAST(\(column) AS DATE) AS TIMESTAMP)"
        default:
            changed = nil
        }
        guard let changed else { return "\(column) IS NOT NULL AND \(failed)" }
        return "\(column) IS NOT NULL AND (\(failed) OR \(changed))"
    }

    // The spelling DuckDB gives a BLOB cast to VARCHAR, for bytes that arrive in a text column.
    static func text(forBytes data: Data) -> String {
        var text = ""
        text.reserveCapacity(data.count)
        for byte in data {
            if (0x20 ... 0x7E).contains(byte), byte != 0x5C, byte != 0x27, byte != 0x22 {
                text.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                text += String(format: "\\x%02X", byte)
            }
        }
        return text
    }
}
