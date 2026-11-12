//
//  ClickHousePartStatements.swift
//  TablePro
//

import Foundation

// ClickHouse takes the database from a request parameter any tab can move, so every statement names its own.
internal enum ClickHousePartStatements {
    internal static func qualifiedName(
        database: String,
        table: String,
        quote: (String) -> String
    ) -> String {
        guard !database.isEmpty else { return quote(table) }
        return "\(quote(database)).\(quote(table))"
    }

    internal static func optimize(
        database: String,
        table: String,
        quote: (String) -> String
    ) -> String {
        "OPTIMIZE TABLE \(qualifiedName(database: database, table: table, quote: quote)) FINAL"
    }

    internal static func dropPartition(
        database: String,
        table: String,
        partitionId: String,
        quote: (String) -> String
    ) -> String? {
        guard isValidPartitionId(partitionId) else { return nil }
        let name = qualifiedName(database: database, table: table, quote: quote)
        return "ALTER TABLE \(name) DROP PARTITION ID '\(partitionId)'"
    }

    internal static func detachPartition(
        database: String,
        table: String,
        partitionId: String,
        quote: (String) -> String
    ) -> String? {
        guard isValidPartitionId(partitionId) else { return nil }
        let name = qualifiedName(database: database, table: table, quote: quote)
        return "ALTER TABLE \(name) DETACH PARTITION ID '\(partitionId)'"
    }

    // The server's own rule (MergeTreePartInfo::validatePartitionID); it also keeps quotes out of the literal.
    internal static func isValidPartitionId(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "0"..."9", "a"..."z", "A"..."Z", "-": true
            default: false
            }
        }
    }

    // With no database of its own, ClickHouse resolves a request against its configured default.
    private static func databasePredicate(_ database: String, escape: (String) -> String) -> String {
        guard !database.isEmpty else { return "currentDatabase()" }
        return "'\(escape(database))'"
    }

    // `partition` renders a tuple key as `(202401,'eu')` and no key as `tuple()`, so statements name `partition_id`.
    internal static func parts(
        database: String,
        table: String,
        escape: (String) -> String
    ) -> String {
        """
        SELECT partition, partition_id, name, rows, bytes_on_disk,
               toString(modification_time) AS mod_time, active
        FROM system.parts
        WHERE database = \(databasePredicate(database, escape: escape)) AND table = '\(escape(table))'
        ORDER BY partition, name
        """
    }
}
