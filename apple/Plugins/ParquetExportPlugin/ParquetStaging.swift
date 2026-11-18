//
//  ParquetStaging.swift
//  ParquetExportPlugin
//

import Foundation

// Kept free of DuckDB so a test bundle can compile it.
enum ParquetStaging {
    enum StagingError: LocalizedError {
        case openFailed
        case queryFailed(String)
        // The database survives this one, so a statement can run again without the limit.
        case memoryExhausted(String)
        // DuckDB invalidates the database when it cannot spill during a checkpoint.
        case stagingLost(String)

        var errorDescription: String? {
            switch self {
            case .openFailed:
                return String(localized: "Could not start the Parquet writer.")
            case .queryFailed(let message), .memoryExhausted(let message), .stagingLost(let message):
                return String(format: String(localized: "Parquet writer failed: %@"), message)
            }
        }
    }

    static let textType = "VARCHAR"
    static let binaryType = "BLOB"

    // DuckDB's own default is 80% of RAM, which a large table fills before anything spills to disk.
    static func memoryLimit(physicalMemory: UInt64) -> UInt64 {
        let gibibyte: UInt64 = 1 << 30
        return min(max(physicalMemory / 16, gibibyte), 4 * gibibyte)
    }

    static func memoryLimitSetting(bytes: UInt64) -> String {
        "\(bytes >> 20)MiB"
    }

    // A value larger than the limit, or a disk too full to spill to, exports today, so it still has to.
    static func retryingWithoutMemoryLimit<Result>(
        limit: UInt64,
        _ attempt: (UInt64?) async throws -> Result
    ) async throws -> Result {
        do {
            return try await attempt(limit)
        } catch StagingError.memoryExhausted, StagingError.stagingLost {
            return try await attempt(nil)
        }
    }

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
        var text: [UInt8] = []
        text.reserveCapacity(data.count)
        for byte in data {
            if (0x20 ... 0x7E).contains(byte), byte != 0x5C, byte != 0x27, byte != 0x22 {
                text.append(byte)
            } else {
                text.append(UInt8(ascii: "\\"))
                text.append(UInt8(ascii: "x"))
                PluginHexText.appendUppercase(byte, to: &text)
            }
        }
        return String(decoding: text, as: UTF8.self)
    }
}
