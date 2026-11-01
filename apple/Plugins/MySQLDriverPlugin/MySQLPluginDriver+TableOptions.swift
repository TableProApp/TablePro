//
//  MySQLPluginDriver+TableOptions.swift
//  MySQLDriverPlugin
//
//  The table options reads and write, and the character set, collation and engine catalog they share
//  with Create Database.
//

import Foundation
import os
import TableProMySQLCore
import TableProPluginKit

internal enum MySQLCatalogColumn: String {
    case checkConstraintLevel = "CHECK_CONSTRAINTS.LEVEL"
    case fullCollationName = "COLLATION_CHARACTER_SET_APPLICABILITY.FULL_COLLATION_NAME"

    var presenceQuery: String {
        let parts = rawValue.split(separator: ".", maxSplits: 1).map(String.init)
        return """
            SELECT COUNT(*)
            FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = 'information_schema'
                AND TABLE_NAME = '\(parts[0])'
                AND COLUMN_NAME = '\(parts[1])'
            """
    }
}

extension MySQLPluginDriver {
    func fetchTableOptions(table: String, schema: String?) async throws -> PluginTableOptions? {
        let sessionFlavor = flavor
        guard MySQLTableOptions.writesOptions(flavor: sessionFlavor),
              serverHasInformationSchema,
              await !resolvesToTemporaryTable(table, schema: schema)
        else { return nil }
        let result = try await execute(
            ownStatement: MySQLTableOptions.tableQuery(schema: effectiveSchema(schema), table: table)
        )
        guard let row = MySQLTableOptionsRow.row(named: table, in: result.rows), row.takesTableOptions else {
            return nil
        }
        // MariaDB's catalog counter is live, and its NO_TABLE_OPTIONS blanks the options line.
        var optionsLine: [String: String]?
        if sessionFlavor == .mysql, row.hasAutoIncrementColumn {
            optionsLine = try await createTableOptions(table: table, schema: schema)
        }
        return MySQLTableOptions.tableOptions(row: row, createTableOptions: optionsLine)
    }

    func fetchTableOptionsCatalog() async throws -> PluginTableOptionsCatalog? {
        guard MySQLTableOptions.readsCatalog(flavor: flavor) else { return nil }
        let characterSets = try await fetchCharsetDefaults()
        guard !characterSets.isEmpty else { return nil }
        let collations = try await fetchCollationCatalog()
        let engines = try await fetchStorageEngines()
        return MySQLTableOptions.catalog(characterSets: characterSets, collations: collations, engines: engines)
    }

    func fetchDefaultTableOptions(schema: String?) async throws -> PluginTableOptions? {
        let database = effectiveSchema(schema)
        guard MySQLTableOptions.readsCatalog(flavor: flavor), serverHasInformationSchema, !database.isEmpty else {
            return nil
        }
        let result = try await execute(ownStatement: MySQLTableOptions.schemaDefaultsQuery(schema: database))
        return MySQLTableOptions.schemaDefaults(named: database, in: result.rows)
    }

    func tableOptionsStatement(table: String, schema: String?, change: PluginTableOptionsChange) -> String? {
        guard MySQLTableOptions.writesOptions(flavor: flavor) else { return nil }
        return MySQLTableOptions.statement(
            qualifiedTable: MySQLObjectQueries.qualifiedIdentifier(schema: schema, name: table),
            change: change
        )
    }

    /// Before 5.0.2 the list comes from `SHOW CHARACTER SET`, whose columns are `Charset`,
    /// `Description`, `Default collation` and `Maxlen`.
    func fetchCharsetDefaults() async throws -> [MySQLCharsetDefault] {
        let hasCatalog = serverHasInformationSchema
        let query = hasCatalog ? """
            SELECT CHARACTER_SET_NAME, DESCRIPTION, DEFAULT_COLLATE_NAME
            FROM information_schema.CHARACTER_SETS
            ORDER BY CHARACTER_SET_NAME
            """ : "SHOW CHARACTER SET"
        let result = try await execute(query: query)
        return result.rows.compactMap { row -> MySQLCharsetDefault? in
            guard let charset = row[safe: 0]?.asText,
                  let collation = row[safe: 2]?.asText else {
                return nil
            }
            return MySQLCharsetDefault(
                charset: charset,
                defaultCollation: collation,
                description: row[safe: 1]?.asText?.nilIfEmpty
            )
        }
        .sorted { $0.charset < $1.charset }
    }

    /// MariaDB 10.10+ lists each UCA 14.0 collation in `COLLATIONS` once, with no character set, while the
    /// server stores and reports the full name (`utf8mb4_uca1400_ai_ci`). Only `FULL_COLLATION_NAME`
    /// lists those, so a server that has the column is read from it. Before 5.0.2 the list comes from
    /// `SHOW COLLATION`, whose first two columns are `Collation` and `Charset`.
    func fetchCollationCatalog() async throws -> [MySQLCollationEntry] {
        let query: String
        if !serverHasInformationSchema {
            query = "SHOW COLLATION"
        } else if flavor.isMariaDB, try await catalogHasColumn(.fullCollationName) {
            query = """
                SELECT FULL_COLLATION_NAME, CHARACTER_SET_NAME
                FROM information_schema.COLLATION_CHARACTER_SET_APPLICABILITY
                ORDER BY FULL_COLLATION_NAME
                """
        } else {
            query = """
                SELECT COLLATION_NAME, CHARACTER_SET_NAME
                FROM information_schema.COLLATIONS
                ORDER BY COLLATION_NAME
                """
        }
        let result = try await execute(query: query)
        var seen = Set<String>()
        return result.rows.compactMap { row -> MySQLCollationEntry? in
            guard let collation = row[safe: 0]?.asText,
                  let charset = row[safe: 1]?.asText,
                  seen.insert(collation).inserted else {
                return nil
            }
            return MySQLCollationEntry(collation: collation, charset: charset)
        }
        .sorted { $0.collation < $1.collation }
    }

    /// An engine the server lists with `NO` or `DISABLED` fails `CREATE TABLE` with ERROR 1286. A refused
    /// read leaves the list empty rather than failing the catalog with it.
    func fetchStorageEngines() async throws -> [MySQLStorageEngine] {
        let query = serverHasInformationSchema ? """
            SELECT ENGINE, SUPPORT
            FROM information_schema.ENGINES
            WHERE SUPPORT IN ('YES', 'DEFAULT')
            """ : "SHOW ENGINES"
        do {
            return MySQLTableOptions.engines(fromRows: try await execute(query: query).rows)
        } catch let error as MariaDBPluginError
            where MySQLCatalogVisibilityRule.settlesBlindness(code: error.code) {
            Self.logger.warning("storage engine read refused code=\(error.code, privacy: .public) message=\(error.message)")
            return []
        }
    }

    /// A server that refuses the question has no such column for this read, and is asked again next time.
    func catalogHasColumn(_ column: MySQLCatalogColumn) async throws -> Bool {
        if let known = cachedCatalogColumnPresence(column.rawValue) { return known }
        let result: PluginQueryResult
        do {
            result = try await execute(ownStatement: column.presenceQuery)
        } catch let error as MariaDBPluginError
            where MySQLCatalogVisibilityRule.settlesBlindness(code: error.code) {
            return false
        }
        let present = (result.rows.first?[safe: 0]?.asText.flatMap { Int($0) } ?? 0) > 0
        cacheCatalogColumnPresence(column.rawValue, present)
        return present
    }

    private func createTableOptions(table: String, schema: String?) async throws -> [String: String]? {
        let result = try await execute(query: "SHOW CREATE TABLE \(qualifiedName(table, schema: schema))")
        return result.rows.first?[safe: 1]?.asText.flatMap(MySQLCreateTableScanner.tableOptions(fromCreateTable:))
    }
}
