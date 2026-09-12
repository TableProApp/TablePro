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
    ///
    /// The row and those constraints are read through one scope. A qualified name only reaches
    /// inside the database the connection is already on, so a row taken from the session driver
    /// while the keys came from the reference's own scope described two different tables wherever
    /// the tab and the sidebar had drifted apart.
    static func fetch(
        origin: DatabaseScope,
        databaseType: DatabaseType,
        reference: JSONForeignKeyRef,
        value: String,
        includeForeignKeys: Bool = false
    ) async throws -> FetchedRow? {
        guard DatabaseManager.shared.driver(for: origin.connectionId) != nil else {
            throw FetchFailure.noConnection
        }
        let target = ForeignKeyTargetScope.resolve(
            origin: origin,
            referencedSchema: reference.referencedSchema,
            databaseType: databaseType
        )
        let dialect = PluginManager.shared.sqlDialect(for: databaseType)

        let result = try await DatabaseManager.shared.withMetadataDriver(scope: target) { driver in
            let quotedTable = SchemaQualifiedName.render(
                name: reference.referencedTable,
                schema: target.schema,
                databaseType: databaseType,
                quote: driver.quoteIdentifier
            )
            let query = ForeignKeyPreviewQuery.singleRow(
                quotedTable: quotedTable,
                quotedColumn: driver.quoteIdentifier(reference.referencedColumn),
                escapedValue: driver.escapeStringLiteral(value),
                stringLiteralPrefix: SQLStringLiteralPrefix.forDatabaseType(databaseType),
                dialect: dialect
            )
            return try await driver.execute(query: query)
        }
        guard let firstRow = result.rows.first else { return nil }

        let foreignKeys = includeForeignKeys
            ? await referencedTableForeignKeys(target: target, reference: reference)
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
    ///
    /// Resolved from the grid's own scope, never the sidebar's: the row above it is read from a
    /// name qualified by the reference itself, so taking the nested keys from the browse cursor
    /// instead put a chevron on a row of one database that navigated into another's. And the
    /// referenced value goes through `ForeignKeyTargetScope` rather than into `schema:` directly,
    /// because on an engine with no schema layer it names a database and the schema slot is inert.
    private static func referencedTableForeignKeys(
        target targetScope: DatabaseScope,
        reference: JSONForeignKeyRef
    ) async -> [String: JSONForeignKeyRef] {
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
