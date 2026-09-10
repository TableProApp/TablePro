//
//  ForeignKeyLookupService.swift
//  TablePro
//
//  The two reads behind the foreign key value picker: the referenced table's columns, and the
//  rows matching what the user typed.
//

import Foundation
import TableProPluginKit

@MainActor
enum ForeignKeyLookupService {
    struct Row: Identifiable, Hashable, Sendable {
        let id: Int
        let key: String
        let label: String?
    }

    enum LookupFailure: Error {
        case noDialect
    }

    private static let classifier = ColumnTypeClassifier()

    /// The referenced table's columns, for the label picker and for typing the search predicate.
    ///
    /// A metadata read, so it goes through `withMetadataDriver` like every other one.
    static func referencedColumns(
        in origin: DatabaseScope,
        reference: ForeignKeyInfo
    ) async throws -> [ForeignKeyLookupColumn] {
        let scope = targetScope(from: origin, reference: reference)
        let table = reference.referencedTable
        let schema = reference.referencedSchema
        let columns = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
            try await driver.fetchColumns(table: table, schema: schema)
        }
        return columns.map {
            ForeignKeyLookupColumn(name: $0.name, type: classifier.classify(rawTypeName: $0.dataType))
        }
    }

    /// Rows whose key or label matches `term`, capped at `ForeignKeyLookupQuery.rowLimit`.
    ///
    /// Empty when the term cannot be expressed as a predicate against either column, which is what
    /// a word typed into a picker on an integer key with no text label comes to. No query is sent
    /// in that case.
    ///
    /// Routed through `withMetadataDriver` rather than the session driver, which the single-row
    /// preview uses: a search runs on every keystroke, and the session driver is the one carrying
    /// the user's own query.
    static func search(
        in origin: DatabaseScope,
        databaseType: DatabaseType,
        reference: ForeignKeyInfo,
        key: ForeignKeyLookupColumn,
        label: ForeignKeyLookupColumn?,
        term: String
    ) async throws -> [Row] {
        guard let dialect = PluginManager.shared.sqlDialect(for: databaseType) else {
            throw LookupFailure.noDialect
        }
        let scope = targetScope(from: origin, reference: reference)
        let table = reference.referencedTable
        let schema = reference.referencedSchema

        return try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
            guard let query = ForeignKeyLookupQuery.rows(
                quotedTable: quotedTable(table: table, schema: schema, driver: driver),
                key: key,
                label: label,
                searchTerm: term,
                dialect: dialect,
                quoteIdentifier: driver.quoteIdentifier
            ) else {
                return []
            }
            let result = try await driver.execute(query: query)
            return rows(from: result, key: key, label: label)
        }
    }

    nonisolated private static func rows(
        from result: QueryResult,
        key: ForeignKeyLookupColumn,
        label: ForeignKeyLookupColumn?
    ) -> [Row] {
        let labelIndex = ForeignKeyLookupQuery.selectedColumns(key: key, label: label).count > 1 ? 1 : nil
        return result.rows.enumerated().compactMap { index, values in
            guard let keyValue = values.first?.asText else { return nil }
            let labelValue = labelIndex.flatMap { values.indices.contains($0) ? values[$0].asText : nil }
            return Row(id: index, key: keyValue, label: labelValue)
        }
    }

    /// The scope of the table being picked from, taken from the grid's own scope rather than from
    /// ambient browse state: a tab stays on the database it opened, while the sidebar and other
    /// windows move, and resolving the database from session state is how a tab's read lands on
    /// another database.
    nonisolated static func targetScope(from origin: DatabaseScope, reference: ForeignKeyInfo) -> DatabaseScope {
        guard let schema = reference.referencedSchema, !schema.isEmpty else { return origin }
        return DatabaseScope(connectionId: origin.connectionId, database: origin.database, schema: schema)
    }

    nonisolated static func tableScope(from origin: DatabaseScope, reference: ForeignKeyInfo) -> TableScope {
        let scope = targetScope(from: origin, reference: reference)
        return TableScope(
            connectionId: scope.connectionId,
            database: scope.database,
            schema: scope.schema,
            table: reference.referencedTable
        )
    }

    nonisolated private static func quotedTable(table: String, schema: String?, driver: DatabaseDriver) -> String {
        guard let schema, !schema.isEmpty else { return driver.quoteIdentifier(table) }
        return "\(driver.quoteIdentifier(schema)).\(driver.quoteIdentifier(table))"
    }
}
