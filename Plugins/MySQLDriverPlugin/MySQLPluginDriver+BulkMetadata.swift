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
        let database = mysqlQuoteIdentifier(routineSchema(schema))
        let result = try await execute(query: "SHOW TABLE STATUS FROM \(database)")
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
