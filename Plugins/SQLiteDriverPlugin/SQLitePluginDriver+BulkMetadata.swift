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

extension SQLitePluginDriver {
    var providesBulkIndexFetch: Bool { true }

    func fetchAllIndexes(schema: String?) async throws -> [String: [PluginIndexInfo]] {
        let result = try await execute(query: SQLiteIndexCatalog.schemaIndexesQuery)
        return SQLiteIndexCatalog.indexesByTable(fromRows: result.rows)
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
