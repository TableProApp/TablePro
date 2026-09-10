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
        let schemaLiteral = escapeLiteral(schema ?? core.currentSchema)
        let columnOrdering = versionedCapabilities.hasArrayPosition
            ? "ORDER BY array_position(ix.indkey, a.attnum)"
            : "ORDER BY a.attnum"
        let query = """
            SELECT
                t.relname AS table_name,
                i.relname AS index_name,
                ARRAY_AGG(a.attname \(columnOrdering)) AS columns,
                ix.indisunique AS is_unique,
                ix.indisprimary AS is_primary,
                am.amname AS index_type,
                pg_get_expr(ix.indpred, ix.indrelid) AS predicate
            FROM pg_index ix
            JOIN pg_class i ON i.oid = ix.indexrelid
            JOIN pg_class t ON t.oid = ix.indrelid
            JOIN pg_namespace n ON n.oid = t.relnamespace
            JOIN pg_am am ON am.oid = i.relam
            JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY(ix.indkey)
            WHERE n.nspname = '\(schemaLiteral)'
            GROUP BY t.relname, i.relname, ix.indisunique, ix.indisprimary, am.amname, ix.indpred, ix.indrelid
            ORDER BY t.relname, ix.indisprimary DESC, i.relname
            """
        let result = try await execute(query: query)

        var indexes: [String: [PluginIndexInfo]] = [:]
        for row in result.rows {
            guard row.count >= 6, let table = row[0].asText,
                  let index = PostgreSQLIndexRow.index(from: row) else { continue }
            indexes[table, default: []].append(index)
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

enum PostgreSQLIndexRow {
    /// The shared shaping for a `pg_index` row, so the per-table and whole-schema reads cannot
    /// disagree about how an index is named, ordered or typed. The row's first field is the table
    /// name in the bulk form and the index name in the per-table form, so the offset is passed in.
    static func index(from row: [PluginCellValue], offset: Int = 1) -> PluginIndexInfo? {
        guard let name = row[safe: offset]?.asText,
              let columnsText = row[safe: offset + 1]?.asText else { return nil }
        let columns = columnsText
            .trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
            .components(separatedBy: ",")
        return PluginIndexInfo(
            name: name,
            columns: columns,
            isUnique: row[safe: offset + 2]?.asText == "t",
            isPrimary: row[safe: offset + 3]?.asText == "t",
            type: row[safe: offset + 4]?.asText?.uppercased() ?? "BTREE",
            whereClause: row[safe: offset + 5]?.asText
        )
    }
}
