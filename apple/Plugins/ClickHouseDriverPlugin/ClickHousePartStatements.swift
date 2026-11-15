//
//  ClickHousePartStatements.swift
//  ClickHouseDriverPlugin
//

import Foundation
import TableProPluginKit

// ClickHouse takes the database from a request parameter any tab can move, so every statement names its own.
nonisolated enum ClickHousePartStatements {
    static func qualifiedName(database: String, table: String, quote: (String) -> String) -> String {
        guard !database.isEmpty else { return quote(table) }
        return "\(quote(database)).\(quote(table))"
    }

    static func optimize(database: String, table: String, quote: (String) -> String) -> String {
        "OPTIMIZE TABLE \(qualifiedName(database: database, table: table, quote: quote)) FINAL"
    }

    static func dropPartition(
        database: String,
        table: String,
        partitionId: String,
        quote: (String) -> String
    ) -> String? {
        guard isValidPartitionId(partitionId) else { return nil }
        return "ALTER TABLE \(qualifiedName(database: database, table: table, quote: quote)) DROP PARTITION ID '\(partitionId)'"
    }

    static func detachPartition(
        database: String,
        table: String,
        partitionId: String,
        quote: (String) -> String
    ) -> String? {
        guard isValidPartitionId(partitionId) else { return nil }
        return "ALTER TABLE \(qualifiedName(database: database, table: table, quote: quote)) DETACH PARTITION ID '\(partitionId)'"
    }

    // The server's own rule (MergeTreePartInfo::validatePartitionID); it also keeps quotes out of the literal.
    static func isValidPartitionId(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "0"..."9", "a"..."z", "A"..."Z", "-": true
            default: false
            }
        }
    }

    // `partition` renders a tuple key as `(202401,'eu')` and no key as `tuple()`, so statements name `partition_id`.
    // With no database of its own, ClickHouse resolves a request against its configured default.
    static func parts(database: String, table: String) -> String {
        """
        SELECT partition, partition_id, name, rows, bytes_on_disk,
               toString(modification_time) AS mod_time, active
        FROM system.parts
        WHERE database = \(ClickHousePluginDriver.databaseExpression(database)) \
        AND table = \(ClickHousePluginDriver.stringLiteral(table))
        ORDER BY partition, name
        """
    }

    // Column order is `parts`.
    static func part(from row: [PluginCellValue]) -> PluginStoragePart? {
        guard let name = row[safe: 2]?.asText else { return nil }
        return PluginStoragePart(
            partition: row[safe: 0]?.asText ?? "",
            partitionId: row[safe: 1]?.asText ?? "",
            name: name,
            rows: row[safe: 3]?.asText.flatMap { UInt64($0) } ?? 0,
            bytesOnDisk: row[safe: 4]?.asText.flatMap { UInt64($0) } ?? 0,
            modificationTime: row[safe: 5]?.asText ?? "",
            isActive: row[safe: 6]?.asText == "1"
        )
    }
}
