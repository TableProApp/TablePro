//
//  ForeignKeyRowFetcher.swift
//  TablePro
//
//  The single-row lookup behind Preview Referenced Row and the JSON inspector's
//  foreign key expansion.
//

import Foundation
import os
import TableProPluginKit

@MainActor
enum ForeignKeyRowFetcher {
    struct FetchedRow: Sendable {
        let columns: [String]
        let columnTypes: [ColumnType]
        let values: [PluginCellValue]
        let foreignKeys: [String: JSONForeignKeyRef]
    }

    enum FetchFailure: Error {
        case noConnection
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "ForeignKeyRowFetcher")

    /// The referenced row, or nil when the key matches nothing. Two callers share this so the
    /// popover and the inspector cannot end up reading a foreign key two different ways.
    ///
    /// `includeForeignKeys` costs a metadata read for the referenced table's own constraints, which
    /// only the inspector needs: it is what makes a nested key clickable in turn.
    static func fetch(
        connectionId: UUID,
        databaseType: DatabaseType,
        reference: JSONForeignKeyRef,
        value: String,
        includeForeignKeys: Bool = false
    ) async throws -> FetchedRow? {
        guard let driver = DatabaseManager.shared.driver(for: connectionId) else {
            throw FetchFailure.noConnection
        }

        let quotedTable: String
        if let schema = reference.referencedSchema, !schema.isEmpty {
            quotedTable = "\(driver.quoteIdentifier(schema)).\(driver.quoteIdentifier(reference.referencedTable))"
        } else {
            quotedTable = driver.quoteIdentifier(reference.referencedTable)
        }

        let query = ForeignKeyPreviewQuery.singleRow(
            quotedTable: quotedTable,
            quotedColumn: driver.quoteIdentifier(reference.referencedColumn),
            escapedValue: driver.escapeStringLiteral(value),
            dialect: PluginManager.shared.sqlDialect(for: databaseType)
        )

        let result = try await driver.execute(query: query)
        guard let firstRow = result.rows.first else { return nil }

        let foreignKeys = includeForeignKeys
            ? await referencedTableForeignKeys(connectionId: connectionId, reference: reference)
            : [:]

        return FetchedRow(
            columns: result.columns,
            columnTypes: result.columnTypes,
            values: firstRow,
            foreignKeys: foreignKeys
        )
    }

    /// Answers from the schema prefetch when it covers the table, so following a chain of keys in
    /// the same schema costs no extra round trips.
    private static func referencedTableForeignKeys(
        connectionId: UUID,
        reference: JSONForeignKeyRef
    ) async -> [String: JSONForeignKeyRef] {
        guard let scope = DatabaseManager.shared.browseScope(for: connectionId) else { return [:] }
        let targetScope = reference.referencedSchema.map {
            DatabaseScope(connectionId: connectionId, database: scope.database, schema: $0)
        } ?? scope

        if let cached = SchemaForeignKeyStore.shared.foreignKeysByColumn(
            for: targetScope,
            table: reference.referencedTable
        ) {
            return cached.mapValues(JSONForeignKeyRef.init)
        }

        do {
            let table = reference.referencedTable
            let fetched = try await DatabaseManager.shared.withMetadataDriver(scope: targetScope) { driver in
                try await driver.fetchForeignKeys(table: table)
            }
            return Dictionary(
                fetched.map { ($0.column, JSONForeignKeyRef($0)) },
                uniquingKeysWith: { first, _ in first }
            )
        } catch {
            logger.error("Nested foreign key metadata fetch failed: \(error.localizedDescription)")
            return [:]
        }
    }
}
