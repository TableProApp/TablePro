//
//  MySQLPluginDriver+BulkMetadata.swift
//  MySQLDriverPlugin
//
//  Whole-schema reads of the metadata that otherwise costs one round trip per
//  table.
//
//  A caller comparing two schemas pays four reads per table without these, so a
//  200-table database is 800 round trips per side. Both queries here are the
//  unfiltered form of the per-table statement, so they answer the same question
//  for every table at once.
//
//  The shaping is shared with the per-table reads rather than written twice. Two
//  copies of the same grouping is how a bulk read drifts from the read it stands
//  in for, and a comparison built on the drifted one reports a real difference as
//  no difference.
//

import Foundation
import TableProPluginKit

/// One row of `SHOW INDEX` or `INFORMATION_SCHEMA.STATISTICS`, in the fields both spell the same.
struct MySQLIndexRow {
    let table: String
    let index: String
    let column: String
    let isNonUnique: Bool
    let type: String
    let prefixLength: Int?
}

enum MySQLIndexGrouping {
    /// Rows must arrive in index-position order: a composite index takes its column order from the
    /// order they are appended, which is what the caller's `ORDER BY … SEQ_IN_INDEX` provides.
    static func group(_ rows: [MySQLIndexRow]) -> [String: [PluginIndexInfo]] {
        var byTable: [String: [String: (columns: [String], isUnique: Bool, type: String, prefixes: [String: Int])]] = [:]

        for row in rows {
            var indexes = byTable[row.table] ?? [:]
            if var existing = indexes[row.index] {
                existing.columns.append(row.column)
                if let prefix = row.prefixLength {
                    existing.prefixes[row.column] = prefix
                }
                indexes[row.index] = existing
            } else {
                var prefixes: [String: Int] = [:]
                if let prefix = row.prefixLength {
                    prefixes[row.column] = prefix
                }
                indexes[row.index] = (
                    columns: [row.column], isUnique: !row.isNonUnique, type: row.type, prefixes: prefixes
                )
            }
            byTable[row.table] = indexes
        }

        return byTable.mapValues { indexes in
            indexes
                .map { name, info in
                    PluginIndexInfo(
                        name: name, columns: info.columns, isUnique: info.isUnique,
                        isPrimary: name == "PRIMARY", type: info.type,
                        columnPrefixes: info.prefixes.isEmpty ? nil : info.prefixes
                    )
                }
                .sorted { $0.isPrimary && !$1.isPrimary }
        }
    }
}

extension MySQLPluginDriver {
    var providesBulkIndexFetch: Bool { true }

    /// `INFORMATION_SCHEMA.STATISTICS` is `SHOW INDEX` for every table at once, and reports the
    /// same fields under the same names. `NON_UNIQUE` and `SUB_PART` are integers here where
    /// `SHOW INDEX` returns text, so both are cast rather than read through a text accessor that
    /// would depend on how the driver rendered an integer cell.
    func fetchAllIndexes(schema: String?) async throws -> [String: [PluginIndexInfo]] {
        let escapedDb = activeDatabaseName.replacingOccurrences(of: "'", with: "''")
        let query = """
            SELECT
                TABLE_NAME, INDEX_NAME, COLUMN_NAME,
                CAST(NON_UNIQUE AS CHAR), INDEX_TYPE, CAST(SUB_PART AS CHAR)
            FROM INFORMATION_SCHEMA.STATISTICS
            WHERE TABLE_SCHEMA = '\(escapedDb)'
            ORDER BY TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX
            """

        let result = try await execute(query: query)
        let rows = result.rows.compactMap { row -> MySQLIndexRow? in
            guard let table = row[safe: 0]?.asText,
                  let index = row[safe: 1]?.asText,
                  let column = row[safe: 2]?.asText
            else { return nil }
            return MySQLIndexRow(
                table: table,
                index: index,
                column: column,
                isNonUnique: (row[safe: 3]?.asText) == "1",
                type: (row[safe: 4]?.asText) ?? "BTREE",
                prefixLength: (row[safe: 5]?.asText).flatMap { Int($0) }
            )
        }
        return MySQLIndexGrouping.group(rows)
    }

    var providesBulkTableMetadataFetch: Bool { true }

    /// `SHOW TABLE STATUS` with no `WHERE` is the whole schema, in the same column order the
    /// per-table read indexes into.
    func fetchAllTableMetadata(schema: String?) async throws -> [String: PluginTableMetadata] {
        let result = try await execute(query: "SHOW TABLE STATUS")
        var metadata: [String: PluginTableMetadata] = [:]
        for row in result.rows {
            guard let name = row[safe: 0]?.asText else { continue }
            metadata[name] = MySQLTableStatusRow.metadata(from: row, tableName: name)
        }
        return metadata
    }
}

enum MySQLTableStatusRow {
    /// The positions `SHOW TABLE STATUS` documents, read in one place so the per-table and
    /// whole-schema reads cannot index the same row differently.
    static func metadata(from row: [PluginCellValue], tableName: String) -> PluginTableMetadata {
        let dataSize = (row[safe: 6]?.asText).flatMap { Int64($0) }
        let indexSize = (row[safe: 8]?.asText).flatMap { Int64($0) }
        let comment = row[safe: 17]?.asText

        let totalSize: Int64? = {
            guard let data = dataSize, let index = indexSize else { return nil }
            return data + index
        }()

        return PluginTableMetadata(
            tableName: tableName,
            dataSize: dataSize,
            indexSize: indexSize,
            totalSize: totalSize,
            rowCount: (row[safe: 4]?.asText).flatMap { Int64($0) },
            comment: comment?.isEmpty == true ? nil : comment,
            engine: row[safe: 1]?.asText,
            collation: row[safe: 14]?.asText?.nilIfEmpty
        )
    }
}
