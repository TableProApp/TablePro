//
//  CockroachPluginDriver.swift
//  PostgreSQLDriverPlugin
//
//  CockroachDB PluginDatabaseDriver implementation.
//  CockroachDB speaks the PostgreSQL wire protocol, so it shares the libpq
//  connection core. Schema introspection uses information_schema and the
//  CockroachDB-native SHOW statements where pg_catalog does not fit.
//

import Foundation
import os
import TableProPluginKit

final class CockroachPluginDriver: LibPQBackedDriver, @unchecked Sendable {
    let core: LibPQDriverCore

    private static let logger = Logger(subsystem: "com.TablePro.PostgreSQLDriver", category: "CockroachPluginDriver")

    private var cachedServerVersion: String?

    var capabilities: PluginCapabilities {
        [
            .parameterizedQueries,
            .transactions,
            .multiSchema,
            .cancelQuery,
            .batchExecute,
            .materializedViews,
        ]
    }

    init(config: DriverConnectionConfig) {
        self.core = LibPQDriverCore(config: config)
    }

    // MARK: - Connection

    func connect() async throws {
        try await core.connect()

        if let result = try? await core.execute(query: "SELECT version()"),
           let version = result.rows.first?.first?.asText {
            cachedServerVersion = version
        }
    }

    var serverVersion: String? {
        cachedServerVersion ?? core.serverVersion
    }

    // MARK: - EXPLAIN

    func buildExplainQuery(_ sql: String) -> String? {
        "EXPLAIN \(sql)"
    }

    // MARK: - Schema

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        let schemaLiteral = escapeLiteral(schema ?? core.currentSchema)
        let query = """
            SELECT table_name, table_type
            FROM information_schema.tables
            WHERE table_schema = '\(schemaLiteral)'
            ORDER BY table_name
            """
        let result = try await execute(query: query)
        return result.rows.compactMap { row -> PluginTableInfo? in
            guard let name = row[0].asText else { return nil }
            let typeStr = (row[1].asText ?? "BASE TABLE").uppercased()
            let type = typeStr.contains("VIEW") ? "VIEW" : "TABLE"
            return PluginTableInfo(name: name, type: type)
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let safeTable = escapeLiteral(table)
        let schemaLiteral = escapeLiteral(schema ?? core.currentSchema)
        let query = Self.columnsQuery(schemaLiteral: schemaLiteral, tableFilter: "AND c.table_name = '\(safeTable)'")
        let result = try await execute(query: query)
        return result.rows.compactMap { Self.mapColumnRow($0, includesTableName: false) }
    }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        let schemaLiteral = escapeLiteral(schema ?? core.currentSchema)
        let query = Self.columnsQuery(schemaLiteral: schemaLiteral, tableFilter: "", includesTableName: true)
        let result = try await execute(query: query)
        var allColumns: [String: [PluginColumnInfo]] = [:]
        for row in result.rows {
            guard let tableName = row.first?.asText,
                  let column = Self.mapColumnRow(row, includesTableName: true) else { continue }
            allColumns[tableName, default: []].append(column)
        }
        return allColumns
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        let quotedTable = quoteIdentifier(table)
        let query = "SHOW INDEXES FROM \(quoteIdentifier(core.currentSchema)).\(quotedTable)"
        let result = try await execute(query: query)

        guard let columnIndex = result.columns.firstIndex(of: "column_name"),
              let nameIndex = result.columns.firstIndex(of: "index_name") else {
            return []
        }
        let nonUniqueIndex = result.columns.firstIndex(of: "non_unique")
        let implicitIndex = result.columns.firstIndex(of: "implicit")

        var columnsByIndex: [String: [String]] = [:]
        var uniqueByIndex: [String: Bool] = [:]
        var order: [String] = []

        for row in result.rows {
            guard nameIndex < row.count, columnIndex < row.count,
                  let indexName = row[nameIndex].asText,
                  let columnName = row[columnIndex].asText else { continue }

            if let implicitIndex, implicitIndex < row.count,
               row[implicitIndex].asText.map(Self.isTruthy) == true {
                continue
            }

            if columnsByIndex[indexName] == nil {
                order.append(indexName)
                if let nonUniqueIndex, nonUniqueIndex < row.count {
                    uniqueByIndex[indexName] = row[nonUniqueIndex].asText.map(Self.isTruthy) == false
                } else {
                    uniqueByIndex[indexName] = false
                }
            }
            columnsByIndex[indexName, default: []].append(columnName)
        }

        return order.map { name in
            PluginIndexInfo(
                name: name,
                columns: columnsByIndex[name] ?? [],
                isUnique: uniqueByIndex[name] ?? false,
                isPrimary: name.hasSuffix("_pkey") || name.lowercased() == "primary"
            )
        }
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        let safeTable = escapeLiteral(table)
        let schemaLiteral = escapeLiteral(schema ?? core.currentSchema)
        let query = """
            SELECT
                tc.constraint_name,
                kcu.column_name,
                ccu.table_name AS referenced_table,
                ccu.column_name AS referenced_column,
                rc.delete_rule,
                rc.update_rule
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
                ON tc.constraint_name = kcu.constraint_name
                AND tc.table_schema = kcu.table_schema
            JOIN information_schema.referential_constraints rc
                ON tc.constraint_name = rc.constraint_name
                AND tc.table_schema = rc.constraint_schema
            JOIN information_schema.constraint_column_usage ccu
                ON rc.unique_constraint_name = ccu.constraint_name
                AND rc.unique_constraint_schema = ccu.table_schema
            WHERE tc.table_name = '\(safeTable)'
                AND tc.table_schema = '\(schemaLiteral)'
                AND tc.constraint_type = 'FOREIGN KEY'
            ORDER BY tc.constraint_name
            """
        let result = try await execute(query: query)
        return result.rows.compactMap { row -> PluginForeignKeyInfo? in
            guard row.count >= 6,
                  let name = row[0].asText,
                  let column = row[1].asText,
                  let refTable = row[2].asText,
                  let refColumn = row[3].asText
            else { return nil }
            return PluginForeignKeyInfo(
                name: name,
                column: column,
                referencedTable: refTable,
                referencedColumn: refColumn,
                onDelete: row[4].asText ?? "NO ACTION",
                onUpdate: row[5].asText ?? "NO ACTION"
            )
        }
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let quotedTable = quoteIdentifier(table)
        let result = try await execute(query: "SHOW CREATE TABLE \(quoteIdentifier(core.currentSchema)).\(quotedTable)")
        guard let ddl = Self.createStatement(from: result) else {
            throw LibPQPluginError(message: "Failed to fetch DDL for table '\(table)'", sqlState: nil, detail: nil)
        }
        return ddl
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        let quotedView = quoteIdentifier(view)
        let result = try await execute(query: "SHOW CREATE VIEW \(quoteIdentifier(core.currentSchema)).\(quotedView)")
        guard let ddl = Self.createStatement(from: result) else {
            throw LibPQPluginError(message: "Failed to fetch definition for view '\(view)'", sqlState: nil, detail: nil)
        }
        return ddl
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table, engine: "CockroachDB")
    }

    func fetchDatabases() async throws -> [String] {
        let result = try await execute(
            query: "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname"
        )
        return result.rows.compactMap { $0.first?.asText }
    }

    func fetchSchemas() async throws -> [String] {
        let result = try await execute(query: PostgreSQLSchemaQueries.listSchemas)
        return result.rows.compactMap { $0.first?.asText }
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        let escapedDb = escapeLiteral(database)
        let query = """
            SELECT COUNT(*)
            FROM information_schema.tables
            WHERE table_catalog = '\(escapedDb)'
              AND table_schema NOT IN ('pg_catalog', 'information_schema', 'crdb_internal', 'pg_extension')
            """
        let tableCount = (try? await execute(query: query))
            .flatMap { $0.rows.first?.first?.asText }
            .flatMap { Int($0) }

        let systemDatabases = ["postgres", "system", "defaultdb"]
        return PluginDatabaseMetadata(
            name: database,
            tableCount: tableCount,
            sizeBytes: nil,
            isSystemDatabase: systemDatabases.contains(database)
        )
    }

    // MARK: - Database Management

    func createDatabaseFormSpec() async throws -> PluginCreateDatabaseFormSpec? {
        PluginCreateDatabaseFormSpec(fields: [])
    }

    func createDatabase(_ request: PluginCreateDatabaseRequest) async throws {
        let quotedName = request.name.replacingOccurrences(of: "\"", with: "\"\"")
        _ = try await execute(query: "CREATE DATABASE \"\(quotedName)\"")
    }

    func dropDatabase(name: String) async throws {
        let quotedName = name.replacingOccurrences(of: "\"", with: "\"\"")
        _ = try await execute(query: "DROP DATABASE \"\(quotedName)\"")
    }

    // MARK: - Query Helpers

    private static func columnsQuery(
        schemaLiteral: String,
        tableFilter: String,
        includesTableName: Bool = false
    ) -> String {
        let selectPrefix = includesTableName ? "c.table_name,\n" : ""
        let orderBy = includesTableName ? "c.table_name, c.ordinal_position" : "c.ordinal_position"
        return """
            SELECT
                \(selectPrefix)c.column_name,
                c.data_type,
                c.is_nullable,
                c.column_default,
                c.collation_name,
                pgd.description,
                c.udt_name,
                CASE WHEN pk.column_name IS NOT NULL THEN 'YES' ELSE 'NO' END AS is_pk
            FROM information_schema.columns c
            LEFT JOIN pg_catalog.pg_class cls
                ON cls.relname = c.table_name
                AND cls.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = c.table_schema)
            LEFT JOIN pg_catalog.pg_description pgd
                ON pgd.objoid = cls.oid
                AND pgd.objsubid = c.ordinal_position
            LEFT JOIN (
                SELECT DISTINCT kcu.table_name, kcu.column_name
                FROM information_schema.table_constraints tc
                JOIN information_schema.key_column_usage kcu
                    ON tc.constraint_name = kcu.constraint_name
                    AND tc.table_schema = kcu.table_schema
                WHERE tc.constraint_type = 'PRIMARY KEY'
                    AND tc.table_schema = '\(schemaLiteral)'
            ) pk ON c.table_name = pk.table_name AND c.column_name = pk.column_name
            WHERE c.table_schema = '\(schemaLiteral)' \(tableFilter)
            ORDER BY \(orderBy)
            """
    }

    private static func mapColumnRow(_ row: [PluginCellValue], includesTableName: Bool) -> PluginColumnInfo? {
        let offset = includesTableName ? 1 : 0
        guard row.count >= offset + 8,
              let name = row[offset].asText,
              let rawDataType = row[offset + 1].asText
        else { return nil }

        let udtName = row[offset + 6].asText
        let dataType: String
        if rawDataType.uppercased() == "USER-DEFINED", let udt = udtName {
            dataType = "ENUM(\(udt))"
        } else {
            dataType = rawDataType.uppercased()
        }

        let isNullable = row[offset + 2].asText == "YES"
        let defaultValue = row[offset + 3].asText
        let collation = row[offset + 4].asText
        let comment = row[offset + 5].asText
        let isPk = row[offset + 7].asText == "YES"

        let charset: String? = collation.flatMap { coll in
            coll.contains(".") ? coll.components(separatedBy: ".").last : nil
        }

        return PluginColumnInfo(
            name: name,
            dataType: dataType,
            isNullable: isNullable,
            isPrimaryKey: isPk,
            defaultValue: defaultValue,
            charset: charset,
            collation: collation,
            comment: comment?.isEmpty == false ? comment : nil
        )
    }

    private static func createStatement(from result: PluginQueryResult) -> String? {
        guard let row = result.rows.first else { return nil }
        let createIndex = result.columns.firstIndex(of: "create_statement") ?? (row.count > 1 ? 1 : 0)
        guard createIndex < row.count, let ddl = row[createIndex].asText, !ddl.isEmpty else { return nil }
        return ddl
    }

    private static func isTruthy(_ value: String) -> Bool {
        let lowered = value.lowercased()
        return lowered == "t" || lowered == "true"
    }
}
