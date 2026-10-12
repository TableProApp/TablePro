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
        let labels: [String?]
    }

    /// A search that could not be expressed is not a search that found nothing, and the picker
    /// says something different about each. Collapsing the two reported "No matching rows" for a
    /// term no column here can hold.
    enum Outcome: Sendable {
        case rows([Row])
        case termNotSearchable
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
        databaseType: DatabaseType,
        reference: ForeignKeyInfo
    ) async throws -> [ForeignKeyLookupColumn] {
        let scope = targetScope(from: origin, databaseType: databaseType, reference: reference)
        let table = reference.referencedTable
        let schema = scope.schema
        let columns = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
            try await driver.fetchColumns(table: table, schema: schema)
        }
        return columns.map {
            ForeignKeyLookupColumn(name: $0.name, type: classifier.classify(rawTypeName: $0.typeNameForClassification))
        }
    }

    /// Rows whose key or one of whose labels matches `term`, capped at
    /// `ForeignKeyLookupQuery.rowLimit`.
    ///
    /// `.termNotSearchable` when the term cannot be expressed as a predicate against any selected
    /// column, which is what a word typed into a picker on an integer key with no text label comes
    /// to. No query is sent in that case.
    ///
    /// Routed through `withMetadataDriver` rather than the session driver, which the single-row
    /// preview uses: a search runs on every keystroke, and the session driver is the one carrying
    /// the user's own query.
    static func search(
        in origin: DatabaseScope,
        databaseType: DatabaseType,
        reference: ForeignKeyInfo,
        key: ForeignKeyLookupColumn,
        labels: [ForeignKeyLookupColumn],
        term: String
    ) async throws -> Outcome {
        guard let dialect = PluginManager.shared.sqlDialect(for: databaseType) else {
            throw LookupFailure.noDialect
        }
        let scope = targetScope(from: origin, databaseType: databaseType, reference: reference)
        let table = reference.referencedTable
        /// Routed to the referenced table's own container and named in full as well. The qualifier
        /// costs nothing and a pooled session can still be moved out from under the read: startup
        /// commands run after the pool connects, so a connection carrying `USE other` answers from
        /// `other` however the scope was resolved.
        let schema = reference.referencedSchema

        return try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
            guard let query = ForeignKeyLookupQuery.rows(
                quotedTable: quotedTable(table: table, schema: schema, driver: driver),
                key: key,
                labels: labels,
                searchTerm: term,
                dialect: dialect,
                stringLiteralPrefix: SQLStringLiteralPrefix.forDatabaseType(databaseType),
                quoteIdentifier: driver.quoteIdentifier
            ) else {
                return .termNotSearchable
            }
            let result = try await driver.execute(query: query)
            return .rows(rows(from: result, key: key, labels: labels))
        }
    }

    /// The labels sit at every select position after the key, however many there are. A row keeps
    /// a NULL as a NULL rather than dropping it here, because how a missing value reads beside the
    /// ones around it is a rendering question that `ForeignKeyLabelText` answers.
    nonisolated private static func rows(
        from result: QueryResult,
        key: ForeignKeyLookupColumn,
        labels: [ForeignKeyLookupColumn]
    ) -> [Row] {
        let labelIndices = ForeignKeyLookupQuery.selectedColumns(key: key, labels: labels).indices.dropFirst()
        return result.rows.enumerated().compactMap { index, values in
            guard let keyValue = values.first?.asText else { return nil }
            let labelValues = labelIndices.map { values.indices.contains($0) ? values[$0].asText : nil }
            return Row(id: index, key: keyValue, labels: labelValues)
        }
    }

    /// The scope of the table being picked from, taken from the grid's own scope rather than from
    /// ambient browse state: a tab stays on the database it opened, while the sidebar and other
    /// windows move, and resolving the database from session state is how a tab's read lands on
    /// another database.
    ///
    /// The read is routed to the referenced table's own container rather than left to a qualifier
    /// alone, because `fetchColumns` reaches the catalog through helpers of its own that take no
    /// schema: MySQL's generated-column read names `activeDatabaseName` directly, so a qualified
    /// `SHOW FULL COLUMNS` would still collect generation expressions from the wrong database.
    static func targetScope(
        from origin: DatabaseScope,
        databaseType: DatabaseType,
        reference: ForeignKeyInfo
    ) -> DatabaseScope {
        ForeignKeyTargetScope.resolve(
            origin: origin,
            referencedDatabase: reference.referencedDatabase,
            referencedSchema: reference.referencedSchema,
            databaseType: databaseType
        )
    }

    static func tableScope(
        from origin: DatabaseScope,
        databaseType: DatabaseType,
        reference: ForeignKeyInfo
    ) -> TableScope {
        ForeignKeyTargetScope.tableScope(
            origin: origin,
            referencedDatabase: reference.referencedDatabase,
            referencedSchema: reference.referencedSchema,
            referencedTable: reference.referencedTable,
            databaseType: databaseType
        )
    }

    nonisolated private static func quotedTable(table: String, schema: String?, driver: DatabaseDriver) -> String {
        SchemaQualifiedName.render(
            name: table,
            schema: schema,
            databaseType: driver.connection.type,
            quote: driver.quoteIdentifier
        )
    }
}
