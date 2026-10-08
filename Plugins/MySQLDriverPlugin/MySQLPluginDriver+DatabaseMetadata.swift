//
//  MySQLPluginDriver+DatabaseMetadata.swift
//  MySQLDriverPlugin
//
//  Table counts and sizes per database, and the all-tables query tab.
//

import Foundation
import os
import TableProPluginKit

internal extension MySQLPluginDriver {
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        let isSystem = systemDatabaseNamesForConnectionType.contains(database)
        guard serverHasInformationSchema else {
            return try await tableStatusMetadata(of: database, isSystem: isSystem)
        }
        let escapedDb = mysqlEscapeStringLiteral(database)

        let query = """
            SELECT COUNT(*), COALESCE(SUM(DATA_LENGTH + INDEX_LENGTH), 0)
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = '\(escapedDb)'
        """
        let result = try await execute(ownStatement: query)
        let row = result.rows.first
        let tableCount = Int(row?[safe: 0]?.asText ?? "0") ?? 0
        let sizeBytes = Int64(row?[safe: 1]?.asText ?? "0") ?? 0

        return PluginDatabaseMetadata(
            name: database,
            tableCount: tableCount,
            sizeBytes: sizeBytes,
            isSystemDatabase: isSystem
        )
    }

    func fetchAllDatabaseMetadata() async throws -> [PluginDatabaseMetadata] {
        let systemDatabases = systemDatabaseNamesForConnectionType
        guard serverHasInformationSchema else {
            var metadata: [PluginDatabaseMetadata] = []
            for database in try await fetchDatabases() {
                try Task.checkCancellation()
                let isSystem = systemDatabases.contains(database)
                metadata.append(try await tableStatusMetadata(of: database, isSystem: isSystem))
            }
            return metadata
        }

        let query = """
            SELECT TABLE_SCHEMA, COUNT(*), COALESCE(SUM(DATA_LENGTH + INDEX_LENGTH), 0)
            FROM information_schema.TABLES
            GROUP BY TABLE_SCHEMA
        """
        let result = try await execute(query: query)

        var metadataByName: [String: PluginDatabaseMetadata] = [:]
        for row in result.rows {
            guard let dbName = row[safe: 0]?.asText else { continue }
            let tableCount = Int((row[safe: 1]?.asText) ?? "0") ?? 0
            let sizeBytes = Int64((row[safe: 2]?.asText) ?? "0") ?? 0
            let isSystem = systemDatabases.contains(dbName)

            metadataByName[dbName] = PluginDatabaseMetadata(
                name: dbName, tableCount: tableCount,
                sizeBytes: sizeBytes, isSystemDatabase: isSystem
            )
        }

        let allDatabases = try await fetchDatabases()
        return allDatabases.map { dbName in
            metadataByName[dbName]
                ?? PluginDatabaseMetadata(name: dbName, isSystemDatabase: systemDatabases.contains(dbName))
        }
    }

    func allTablesMetadataSQL(schema: String?) -> String? {
        guard !flavor.isDatabend else { return DatabendCatalog.allTablesMetadataSQL }
        guard serverHasInformationSchema else { return Self.tableStatusStatement(database: effectiveSchema(schema)) }
        return literalSpelling.respelled("""
        SELECT
            TABLE_SCHEMA as `schema`,
            TABLE_NAME as name,
            TABLE_TYPE as kind,
            IFNULL(CCSA.CHARACTER_SET_NAME, '') as charset,
            TABLE_COLLATION as collation,
            TABLE_ROWS as estimated_rows,
            CONCAT(ROUND((DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 2), ' MB') as total_size,
            CONCAT(ROUND(DATA_LENGTH / 1024 / 1024, 2), ' MB') as data_size,
            CONCAT(ROUND(INDEX_LENGTH / 1024 / 1024, 2), ' MB') as index_size,
            TABLE_COMMENT as comment
        FROM information_schema.TABLES
        LEFT JOIN information_schema.COLLATION_CHARACTER_SET_APPLICABILITY CCSA
            ON TABLE_COLLATION = CCSA.COLLATION_NAME
        WHERE TABLE_SCHEMA = '\(effectiveSchemaLiteral(schema))'
        ORDER BY TABLE_NAME
        """)
    }

    /// Before 5.0.2 there is no catalog to total, so each database answers its own `SHOW TABLE STATUS`.
    /// One the account may list but not open is refused, and keeps its name alone rather than failing
    /// the whole list.
    private func tableStatusMetadata(of database: String, isSystem: Bool) async throws -> PluginDatabaseMetadata {
        let rows: [[PluginCellValue]]
        do {
            rows = try await execute(query: Self.tableStatusStatement(database: database)).rows
        } catch let error as MariaDBPluginError
            where MySQLCatalogVisibilityRule.settlesBlindness(code: error.code) {
            Self.logger.info("SHOW TABLE STATUS refused for one database code=\(error.code, privacy: .public)")
            return PluginDatabaseMetadata(name: database, isSystemDatabase: isSystem)
        }
        let sizeBytes = rows.reduce(Int64(0)) { total, row in
            let data = row[safe: 6]?.asText.flatMap { Int64($0) } ?? 0
            let index = row[safe: 8]?.asText.flatMap { Int64($0) } ?? 0
            return total + data + index
        }
        return PluginDatabaseMetadata(
            name: database,
            tableCount: rows.count,
            sizeBytes: sizeBytes,
            isSystemDatabase: isSystem
        )
    }
}
