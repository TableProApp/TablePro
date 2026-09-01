//
//  SQLitePluginDriver+BulkMetadata.swift
//  SQLiteDriverPlugin
//
//  Whole-schema reads of the metadata that otherwise costs one round trip per
//  table.
//
//  SQLite reaches these through its table-valued pragma functions, so the
//  per-table `PRAGMA index_list` becomes one join against `sqlite_master`. The
//  shaping is shared with the per-table read rather than written twice, because
//  two copies of one grouping is how a bulk read drifts from the read it stands
//  in for.
//

import Foundation
import TableProPluginKit

/// One row of `pragma_index_list` joined to `pragma_index_info`, in the fields both forms carry.
struct SQLiteIndexRow {
    let table: String
    let index: String
    let column: String?
    let isUnique: Bool
    let origin: String
}

enum SQLiteIndexGrouping {
    /// Rows must arrive in index-position order, which is what the caller's
    /// `ORDER BY il.seq, ii.seqno` provides: a composite index takes its column order from the
    /// order they are appended.
    static func group(_ rows: [SQLiteIndexRow]) -> [String: [PluginIndexInfo]] {
        var order: [String: [String]] = [:]
        var entries: [String: [String: (isUnique: Bool, isPrimary: Bool, columns: [String])]] = [:]

        for row in rows {
            var tableEntries = entries[row.table] ?? [:]
            if var existing = tableEntries[row.index] {
                if let column = row.column {
                    existing.columns.append(column)
                }
                tableEntries[row.index] = existing
            } else {
                tableEntries[row.index] = (
                    isUnique: row.isUnique,
                    isPrimary: row.origin == "pk",
                    columns: row.column.map { [$0] } ?? []
                )
                order[row.table, default: []].append(row.index)
            }
            entries[row.table] = tableEntries
        }

        var result: [String: [PluginIndexInfo]] = [:]
        for (table, names) in order {
            result[table] = names.compactMap { name -> PluginIndexInfo? in
                guard let entry = entries[table]?[name] else { return nil }
                return PluginIndexInfo(
                    name: name,
                    columns: entry.columns,
                    isUnique: entry.isUnique,
                    isPrimary: entry.isPrimary,
                    type: "BTREE"
                )
            }
            .sorted { $0.isPrimary && !$1.isPrimary }
        }
        return result
    }
}

extension SQLitePluginDriver {
    var providesBulkIndexFetch: Bool { true }

    func fetchAllIndexes(schema: String?) async throws -> [String: [PluginIndexInfo]] {
        let query = """
            SELECT m.name AS tbl, il.name, il."unique", il.origin, ii.name AS col_name
            FROM sqlite_master m
            JOIN pragma_index_list(m.name) il
            LEFT JOIN pragma_index_info(il.name) ii ON 1=1
            WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite_%'
            ORDER BY m.name, il.seq, ii.seqno
            """
        let result = try await execute(query: query)

        let rows = result.rows.compactMap { row -> SQLiteIndexRow? in
            guard row.count >= 5,
                  let table = row[0].asText,
                  let index = row[1].asText else { return nil }
            return SQLiteIndexRow(
                table: table,
                index: index,
                column: row[4].asText,
                isUnique: row[2].asText == "1",
                origin: row[3].asText ?? "c"
            )
        }
        return SQLiteIndexGrouping.group(rows)
    }

    var providesBulkTableMetadataFetch: Bool { true }

    /// `rowCount` is deliberately absent. SQLite stores no row count, so the per-table read counts
    /// rows with a capped scan, and doing that once per table is the cost this whole-schema read
    /// exists to remove. Everything the metadata says about a table's *structure* is here; a caller
    /// that wants a count asks `fetchTableMetadata` for the one table it cares about.
    func fetchAllTableMetadata(schema: String?) async throws -> [String: PluginTableMetadata] {
        let query = """
            SELECT name FROM sqlite_master
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
            ORDER BY name
            """
        let result = try await execute(query: query)
        var metadata: [String: PluginTableMetadata] = [:]
        for row in result.rows {
            guard let name = row[safe: 0]?.asText else { continue }
            metadata[name] = PluginTableMetadata(tableName: name, engine: "SQLite")
        }
        return metadata
    }
}
