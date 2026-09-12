//
//  PostgreSQLPluginDriver+BulkMetadata.swift
//  PostgreSQLDriverPlugin
//
//  Whole-schema reads of the metadata that otherwise costs one round trip per
//  table.
//
//  Each query here is the per-table statement with its `relname` predicate
//  traded for a namespace predicate and the table name added to the projection,
//  so the two forms answer with the same fields from the same catalogs.
//

import Foundation
import TableProPluginKit

extension PostgreSQLPluginDriver {
    /// The bulk column read shares its projection builder with `fetchColumns`, so it reports
    /// generated columns and their expressions exactly as the per-table read does.
    var providesBulkColumnFetch: Bool { true }

    var providesBulkIndexFetch: Bool { true }

    func fetchAllIndexes(schema: String?) async throws -> [String: [PluginIndexInfo]] {
        let query = PostgreSQLIndexQueries.indexList(schema: schema ?? core.currentSchema, table: nil)
        let result = try await execute(query: query)

        var indexes: [String: [PluginIndexInfo]] = [:]
        for row in result.rows {
            guard let decoded = PostgreSQLIndexRow.index(from: row) else { continue }
            indexes[decoded.table, default: []].append(decoded.index)
        }
        return indexes
    }

    var providesBulkTableMetadataFetch: Bool { true }

    func fetchAllTableMetadata(schema: String?) async throws -> [String: PluginTableMetadata] {
        let schemaLiteral = escapeLiteral(schema ?? core.currentSchema)
        let query = """
            SELECT
                c.relname AS table_name,
                pg_total_relation_size(c.oid) AS total_size,
                pg_table_size(c.oid) AS data_size,
                pg_indexes_size(c.oid) AS index_size,
                c.reltuples::bigint AS row_count,
                obj_description(c.oid, 'pg_class') AS comment
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = '\(schemaLiteral)' AND c.relkind IN ('r', 'p', 'm', 'f')
            ORDER BY c.relname
            """
        let result = try await execute(query: query)

        var metadata: [String: PluginTableMetadata] = [:]
        for row in result.rows {
            guard let name = row[safe: 0]?.asText else { continue }
            let comment = row[safe: 5]?.asText
            metadata[name] = PluginTableMetadata(
                tableName: name,
                dataSize: (row[safe: 2]?.asText).flatMap { Int64($0) },
                indexSize: (row[safe: 3]?.asText).flatMap { Int64($0) },
                totalSize: (row[safe: 1]?.asText).flatMap { Int64($0) },
                rowCount: (row[safe: 4]?.asText).flatMap { Int64($0) },
                comment: comment?.isEmpty == true ? nil : comment,
                engine: "PostgreSQL"
            )
        }
        return metadata
    }
}
