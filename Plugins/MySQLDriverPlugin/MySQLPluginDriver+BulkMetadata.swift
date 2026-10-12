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

extension MySQLPluginDriver {
    var providesBulkIndexFetch: Bool { true }

    /// `INFORMATION_SCHEMA.STATISTICS` is `SHOW INDEX` for every table at once, and reports the
    /// same fields under the same names. `NON_UNIQUE` and `SUB_PART` are integers here where
    /// `SHOW INDEX` returns text, so both are cast rather than read through a text accessor that
    /// would depend on how the driver rendered an integer cell.
    func fetchAllIndexes(schema: String?) async throws -> [String: [PluginIndexInfo]] {
        guard !flavor.isDatabend else { return [:] }
        let database = routineSchema(schema)
        return try await catalogOrShow(
            database: database,
            catalogExists: serverHasInformationSchema,
            catalog: { try await self.catalogIndexes(database: database) },
            show: { try await self.showIndexesByTable(database: database) }
        )
    }

    private func catalogIndexes(database: String) async throws -> [String: [PluginIndexInfo]] {
        let escapedDb = mysqlEscapeStringLiteral(database)
        let identity = serverIdentity
        let expression = MySQLFunctionalKeyParts.catalogReportsExpressions(
            banner: identity.banner, flavor: identity.flavor
        ) ? "EXPRESSION" : "NULL"
        let query = """
            SELECT
                TABLE_NAME, INDEX_NAME, COLUMN_NAME,
                CAST(NON_UNIQUE AS CHAR), INDEX_TYPE, CAST(SUB_PART AS CHAR),
                COLLATION, \(expression)
            FROM INFORMATION_SCHEMA.STATISTICS
            WHERE TABLE_SCHEMA = '\(escapedDb)'
            ORDER BY TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX
            """

        let result = try await execute(ownStatement: query)
        let rows = result.rows.compactMap { row -> MySQLIndexRow? in
            guard let table = row[safe: 0]?.asText,
                  let index = row[safe: 1]?.asText
            else { return nil }
            return MySQLIndexRow(
                table: table,
                index: index,
                column: row[safe: 2]?.asText,
                catalogExpression: row[safe: 7]?.asText,
                prefixLength: (row[safe: 5]?.asText).flatMap { Int($0) },
                collation: row[safe: 6]?.asText,
                isNonUnique: (row[safe: 3]?.asText) == "1",
                type: (row[safe: 4]?.asText) ?? "BTREE"
            )
        }
        return MySQLIndexGrouping.group(rows)
    }

    var providesBulkTableMetadataFetch: Bool { true }

    /// `SHOW TABLE STATUS FROM` with no `WHERE` is the whole schema, in the same column order the
    /// per-table read indexes into. The database is named rather than inherited from the session,
    /// so a caller asking about another one is answered about the one it asked about.
    func fetchAllTableMetadata(schema: String?) async throws -> [String: PluginTableMetadata] {
        guard !flavor.isDatabend else { return try await databendAllTableMetadata(database: routineSchema(schema)) }
        let result = try await execute(query: Self.tableStatusStatement(database: routineSchema(schema)))
        let appendsInnoDBStatus = serverAppendsInnoDBStatus
        var metadata: [String: PluginTableMetadata] = [:]
        for row in result.rows {
            guard let name = row[safe: 0]?.asText else { continue }
            metadata[name] = MySQLTableStatusRow.metadata(
                from: row, tableName: name, appendsInnoDBStatus: appendsInnoDBStatus
            )
        }
        return metadata
    }

    /// Every table's status row in one database. With no database named the session's own is meant,
    /// since `FROM` an empty name is `ERROR 1102`.
    static func tableStatusStatement(database: String) -> String {
        guard !database.isEmpty else { return "SHOW TABLE STATUS" }
        return "SHOW TABLE STATUS FROM \(mysqlQuoteIdentifier(database))"
    }
}
