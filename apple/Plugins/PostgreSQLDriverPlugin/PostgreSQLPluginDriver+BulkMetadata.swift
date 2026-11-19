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

    // Each is the per-table read with its table predicate dropped, decoded by the same row reader.
    var exportBulkReads: PluginExportBulkReads {
        exportCatalog.schemaDDLReads.union([.columns, .foreignKeys, .indexes])
    }

    func fetchAllIndexDDL(schema: String?) async throws -> [String: [String]] {
        try await exportCatalog.fetchAllIndexDDL(schema: schema)
    }

    func fetchAllCommentDDL(schema: String?) async throws -> [String: [String]] {
        try await exportCatalog.fetchAllCommentDDL(schema: schema)
    }

    func fetchAllDependentSequences(schema: String?) async throws -> [String: [PluginSequenceInfo]] {
        try await exportCatalog.fetchAllDependentSequences(schema: schema)
    }

    func fetchAllDependentTypes(schema: String?) async throws -> [String: [PluginEnumTypeInfo]] {
        try await exportCatalog.fetchAllDependentTypes(schema: schema)
    }

    func fetchAllColumnsForExport(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        try await exportCatalog.fetchAllColumnsForExport(schema: schema)
    }

    func fetchAllForeignKeysForExport(schema: String?) async throws -> [String: [PluginForeignKeyInfo]] {
        try await exportCatalog.fetchAllForeignKeysForExport(schema: schema)
    }

    func fetchAllIndexes(schema: String?) async throws -> [String: [PluginIndexInfo]] {
        try await schemaIndexes(schema: schema, keepsSpellingsApart: false)
    }

    func fetchAllIndexesForExport(schema: String?) async throws -> [String: [PluginIndexInfo]] {
        try await schemaIndexes(schema: schema, keepsSpellingsApart: true)
    }

    private func schemaIndexes(schema: String?, keepsSpellingsApart: Bool) async throws -> [String: [PluginIndexInfo]] {
        let resolvedSchema = schema ?? core.currentSchema
        let query = PostgreSQLIndexQueries.indexList(
            schema: resolvedSchema, table: nil, capabilities: catalogCapabilities
        )
        let result = try await catalogRead(query, namesRelativeTo: resolvedSchema)
        let spellings = try await catalogRead(PostgreSQLIndexQueries.indexDDLQuery(schema: resolvedSchema, table: nil))
        return try Self.indexesByTable(
            rows: result.rows, spellingRows: spellings.rows, keepsSpellingsApart: keepsSpellingsApart
        )
    }

    static func indexesByTable(
        rows: [[PluginCellValue]],
        spellingRows: [[PluginCellValue]],
        keepsSpellingsApart: Bool
    ) throws -> [String: [PluginIndexInfo]] {
        if keepsSpellingsApart {
            try PluginNameSpellings.requireDistinctSpellings(
                (rows + spellingRows).compactMap { $0.first?.asText }, failure: PostgreSQLCatalogReadError.twinRelations
            )
        }
        let ddl = PostgreSQLIndexQueries.indexDDL(rows: spellingRows)
        var indexes: [String: [PluginIndexInfo]] = [:]
        for row in rows {
            guard let decoded = PostgreSQLIndexRow.index(from: row, ddl: ddl) else { continue }
            indexes[decoded.table, default: []].append(decoded.index)
        }
        return indexes
    }

    var providesBulkTableMetadataFetch: Bool { true }

    func fetchAllTableMetadata(schema: String?) async throws -> [String: PluginTableMetadata] {
        let query = PostgreSQLSchemaQueries.allTableMetadata(schema: schema ?? core.currentSchema)
        let result = try await catalogRead(query)

        var metadata: [String: PluginTableMetadata] = [:]
        for row in result.rows {
            guard let name = row[safe: 0]?.asText else { continue }
            let comment = row[safe: 5]?.asText
            metadata[name] = PluginTableMetadata(
                tableName: name,
                dataSize: (row[safe: 2]?.asText).flatMap { Int64($0) },
                indexSize: (row[safe: 3]?.asText).flatMap { Int64($0) },
                totalSize: (row[safe: 1]?.asText).flatMap { Int64($0) },
                rowCount: PostgreSQLSchemaQueries.rowEstimate(reltuples: row[safe: 4]?.asText),
                comment: comment?.isEmpty == true ? nil : comment,
                engine: "PostgreSQL"
            )
        }
        return metadata
    }
}
