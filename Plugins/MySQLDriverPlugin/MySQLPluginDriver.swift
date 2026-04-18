//
//  MySQLPluginDriver.swift
//  MySQLDriverPlugin
//
//  MySQL/MariaDB plugin driver conforming to PluginDatabaseDriver
//

import Foundation
import os
import TableProPluginKit

final class MySQLPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let config: DriverConnectionConfig
    private var mariadbConnection: MariaDBPluginConnection?
    private var _serverVersion: String?
    private var _activeDatabase: String

    /// Detected server type from version string after connecting
    private var isMariaDB = false

    private static let logger = Logger(subsystem: "com.TablePro", category: "MySQLPluginDriver")

    var currentSchema: String? { nil }
    var serverVersion: String? { _serverVersion }
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { true }

    func quoteIdentifier(_ name: String) -> String {
        let escaped = name.replacingOccurrences(of: "`", with: "``")
        return "`\(escaped)`"
    }

    func escapeStringLiteral(_ value: String) -> String {
        var result = value
        result = result.replacingOccurrences(of: "\\", with: "\\\\")
        result = result.replacingOccurrences(of: "'", with: "''")
        result = result.replacingOccurrences(of: "\n", with: "\\n")
        result = result.replacingOccurrences(of: "\r", with: "\\r")
        result = result.replacingOccurrences(of: "\t", with: "\\t")
        result = result.replacingOccurrences(of: "\0", with: "\\0")
        result = result.replacingOccurrences(of: "\u{08}", with: "\\b")
        result = result.replacingOccurrences(of: "\u{0C}", with: "\\f")
        result = result.replacingOccurrences(of: "\u{1A}", with: "\\Z")
        return result
    }

    private static let tableNameRegex = try? NSRegularExpression(pattern: "(?i)\\bFROM\\s+[`\"']?([\\w]+)[`\"']?")
    private static let limitRegex = try? NSRegularExpression(pattern: "(?i)\\s+LIMIT\\s+\\d+(\\s*,\\s*\\d+)?")
    private static let offsetRegex = try? NSRegularExpression(pattern: "(?i)\\s+OFFSET\\s+\\d+")

    init(config: DriverConnectionConfig) {
        self.config = config
        self._activeDatabase = config.database
    }

    // MARK: - Connection

    func connect() async throws {
        let sslConfig = MySQLSSLConfig(from: config.additionalFields)

        let conn = MariaDBPluginConnection(
            host: config.host,
            port: config.port,
            user: config.username,
            password: config.password,
            database: _activeDatabase,
            sslConfig: sslConfig
        )

        try await conn.connect()
        mariadbConnection = conn

        if let version = conn.serverVersion() {
            _serverVersion = version
            isMariaDB = version.lowercased().contains("mariadb")
        }
    }

    func disconnect() {
        mariadbConnection?.disconnect()
        mariadbConnection = nil
        _serverVersion = nil
        isMariaDB = false
    }

    func ping() async throws {
        _ = try await execute(query: "SELECT 1")
    }

    // MARK: - Transaction Management

    func beginTransaction() async throws {
        _ = try await execute(query: "START TRANSACTION")
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> PluginQueryResult {
        try await executeWithReconnect(query: query, isRetry: false)
    }

    func executeParameterized(query: String, parameters: [String?]) async throws -> PluginQueryResult {
        guard let conn = mariadbConnection else {
            throw MariaDBPluginError.notConnected
        }

        let startTime = Date()
        let anyParams: [Any?] = parameters.map { $0 as Any? }
        let result = try await conn.executeParameterizedQuery(query, parameters: anyParams)

        return PluginQueryResult(
            columns: result.columns,
            columnTypeNames: result.columnTypeNames,
            rows: result.rows,
            rowsAffected: Int(result.affectedRows),
            executionTime: Date().timeIntervalSince(startTime),
            isTruncated: result.isTruncated
        )
    }

    func cancelQuery() throws {
        mariadbConnection?.cancelCurrentQuery()
    }

    private func executeWithReconnect(query: String, isRetry: Bool) async throws -> PluginQueryResult {
        let startTime = Date()

        guard let conn = mariadbConnection else {
            throw MariaDBPluginError.notConnected
        }

        do {
            let result = try await conn.executeQuery(query)

            if result.columns.isEmpty && result.rows.isEmpty {
                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                let isSelect = trimmed.uppercased().hasPrefix("SELECT")
                if isSelect, let tableName = extractTableName(from: query) {
                    let columns = try await fetchColumnNames(for: tableName)
                    return PluginQueryResult(
                        columns: columns,
                        columnTypeNames: Array(repeating: "TEXT", count: columns.count),
                        rows: [],
                        rowsAffected: Int(result.affectedRows),
                        executionTime: Date().timeIntervalSince(startTime),
                        isTruncated: result.isTruncated
                    )
                }
            }

            return PluginQueryResult(
                columns: result.columns,
                columnTypeNames: result.columnTypeNames,
                rows: result.rows,
                rowsAffected: Int(result.affectedRows),
                executionTime: Date().timeIntervalSince(startTime),
                isTruncated: result.isTruncated
            )
        } catch let error as MariaDBPluginError where !isRetry && isConnectionLostError(error) {
            try await reconnect()
            return try await executeWithReconnect(query: query, isRetry: true)
        }
    }

    private func isConnectionLostError(_ error: MariaDBPluginError) -> Bool {
        [2_006, 2_013, 2_055].contains(Int(error.code))
    }

    private func reconnect() async throws {
        mariadbConnection?.disconnect()
        mariadbConnection = nil
        try await connect()
    }

    // MARK: - Schema Operations

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        let result = try await execute(query: "SHOW FULL TABLES")

        return result.rows.compactMap { row -> PluginTableInfo? in
            guard let name = row[safe: 0] ?? nil else { return nil }
            let typeStr = (row[safe: 1] ?? nil) ?? "BASE TABLE"
            let type = typeStr.contains("VIEW") ? "VIEW" : "TABLE"
            return PluginTableInfo(name: name, type: type)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let safeTable = table.replacingOccurrences(of: "`", with: "``")
        let result = try await execute(query: "SHOW FULL COLUMNS FROM `\(safeTable)`")

        return result.rows.compactMap { row in
            guard let name = row[safe: 0] ?? nil,
                  let dataType = row[safe: 1] ?? nil
            else { return nil }

            let collation = row[safe: 2] ?? nil
            let isNullable = (row[safe: 3] ?? nil) == "YES"
            let isPrimaryKey = (row[safe: 4] ?? nil) == "PRI"
            let defaultValue = row[safe: 5] ?? nil
            let extra = row[safe: 6] ?? nil
            let comment = row[safe: 8] ?? nil

            let charset: String? = {
                guard let coll = collation, coll != "NULL" else { return nil }
                return coll.components(separatedBy: "_").first
            }()

            let upperType = dataType.uppercased()
            let normalizedType = (upperType.hasPrefix("ENUM(") || upperType.hasPrefix("SET("))
                ? dataType : upperType

            return PluginColumnInfo(
                name: name,
                dataType: normalizedType,
                isNullable: isNullable,
                isPrimaryKey: isPrimaryKey,
                defaultValue: defaultValue,
                extra: extra,
                charset: charset,
                collation: collation == "NULL" ? nil : collation,
                comment: comment?.isEmpty == false ? comment : nil
            )
        }
    }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        let dbName = _activeDatabase
        let escapedDb = dbName.replacingOccurrences(of: "'", with: "''")
        let query = """
            SELECT
                TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, COLLATION_NAME,
                IS_NULLABLE, COLUMN_KEY, COLUMN_DEFAULT, EXTRA, COLUMN_COMMENT
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_SCHEMA = '\(escapedDb)'
            ORDER BY TABLE_NAME, ORDINAL_POSITION
            """

        let result = try await execute(query: query)

        var allColumns: [String: [PluginColumnInfo]] = [:]
        for row in result.rows {
            guard let tableName = row[safe: 0] ?? nil,
                  let name = row[safe: 1] ?? nil,
                  let dataType = row[safe: 2] ?? nil
            else { continue }

            let collation = row[safe: 3] ?? nil
            let isNullable = (row[safe: 4] ?? nil) == "YES"
            let isPrimaryKey = (row[safe: 5] ?? nil) == "PRI"
            let defaultValue = row[safe: 6] ?? nil
            let extra = row[safe: 7] ?? nil
            let comment = row[safe: 8] ?? nil

            let charset: String? = {
                guard let coll = collation, coll != "NULL" else { return nil }
                return coll.components(separatedBy: "_").first
            }()

            let upperType = dataType.uppercased()
            let normalizedType = (upperType.hasPrefix("ENUM(") || upperType.hasPrefix("SET("))
                ? dataType : upperType

            let column = PluginColumnInfo(
                name: name,
                dataType: normalizedType,
                isNullable: isNullable,
                isPrimaryKey: isPrimaryKey,
                defaultValue: defaultValue,
                extra: extra,
                charset: charset,
                collation: collation == "NULL" ? nil : collation,
                comment: comment?.isEmpty == false ? comment : nil
            )

            allColumns[tableName, default: []].append(column)
        }

        return allColumns
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        let safeTable = table.replacingOccurrences(of: "`", with: "``")
        let result = try await execute(query: "SHOW INDEX FROM `\(safeTable)`")

        var indexMap: [String: (columns: [String], isUnique: Bool, type: String)] = [:]

        for row in result.rows {
            guard let indexName = row[safe: 2] ?? nil,
                  let columnName = row[safe: 4] ?? nil
            else { continue }

            let nonUnique = (row[safe: 1] ?? nil) == "1"
            let indexType = (row[safe: 10] ?? nil) ?? "BTREE"

            if var existing = indexMap[indexName] {
                existing.columns.append(columnName)
                indexMap[indexName] = existing
            } else {
                indexMap[indexName] = (columns: [columnName], isUnique: !nonUnique, type: indexType)
            }
        }

        return indexMap
            .map { name, info in
                PluginIndexInfo(
                    name: name, columns: info.columns, isUnique: info.isUnique,
                    isPrimary: name == "PRIMARY", type: info.type
                )
            }
            .sorted { $0.isPrimary && !$1.isPrimary }
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        let dbName = _activeDatabase
        let escapedDb = dbName.replacingOccurrences(of: "'", with: "''")
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")

        let query = """
            SELECT
                kcu.CONSTRAINT_NAME,
                kcu.COLUMN_NAME,
                kcu.REFERENCED_TABLE_NAME,
                kcu.REFERENCED_COLUMN_NAME,
                kcu.REFERENCED_TABLE_SCHEMA,
                rc.DELETE_RULE,
                rc.UPDATE_RULE
            FROM information_schema.KEY_COLUMN_USAGE kcu
            JOIN information_schema.REFERENTIAL_CONSTRAINTS rc
                ON kcu.CONSTRAINT_NAME = rc.CONSTRAINT_NAME
                AND kcu.CONSTRAINT_SCHEMA = rc.CONSTRAINT_SCHEMA
            WHERE kcu.TABLE_SCHEMA = '\(escapedDb)'
                AND kcu.TABLE_NAME = '\(escapedTable)'
                AND kcu.REFERENCED_TABLE_NAME IS NOT NULL
            ORDER BY kcu.CONSTRAINT_NAME
            """

        let result = try await execute(query: query)

        return result.rows.compactMap { row in
            guard let name = row[safe: 0] ?? nil,
                  let column = row[safe: 1] ?? nil,
                  let refTable = row[safe: 2] ?? nil,
                  let refColumn = row[safe: 3] ?? nil
            else { return nil }

            return PluginForeignKeyInfo(
                name: name, column: column,
                referencedTable: refTable, referencedColumn: refColumn,
                referencedSchema: row[safe: 4] ?? nil,
                onDelete: (row[safe: 5] ?? nil) ?? "NO ACTION",
                onUpdate: (row[safe: 6] ?? nil) ?? "NO ACTION"
            )
        }
    }

    func fetchAllForeignKeys(schema: String?) async throws -> [String: [PluginForeignKeyInfo]] {
        let dbName = _activeDatabase
        let escapedDb = dbName.replacingOccurrences(of: "'", with: "''")

        let query = """
            SELECT
                kcu.TABLE_NAME,
                kcu.CONSTRAINT_NAME,
                kcu.COLUMN_NAME,
                kcu.REFERENCED_TABLE_NAME,
                kcu.REFERENCED_COLUMN_NAME,
                kcu.REFERENCED_TABLE_SCHEMA,
                rc.DELETE_RULE,
                rc.UPDATE_RULE
            FROM information_schema.KEY_COLUMN_USAGE kcu
            JOIN information_schema.REFERENTIAL_CONSTRAINTS rc
                ON kcu.CONSTRAINT_NAME = rc.CONSTRAINT_NAME
                AND kcu.CONSTRAINT_SCHEMA = rc.CONSTRAINT_SCHEMA
            WHERE kcu.TABLE_SCHEMA = '\(escapedDb)'
                AND kcu.REFERENCED_TABLE_NAME IS NOT NULL
            ORDER BY kcu.TABLE_NAME, kcu.CONSTRAINT_NAME
            """
        let result = try await execute(query: query)

        var grouped: [String: [PluginForeignKeyInfo]] = [:]
        for row in result.rows {
            guard let tableName = row[safe: 0] ?? nil,
                  let name = row[safe: 1] ?? nil,
                  let column = row[safe: 2] ?? nil,
                  let refTable = row[safe: 3] ?? nil,
                  let refColumn = row[safe: 4] ?? nil
            else { continue }

            let fk = PluginForeignKeyInfo(
                name: name, column: column,
                referencedTable: refTable, referencedColumn: refColumn,
                referencedSchema: row[safe: 5] ?? nil,
                onDelete: (row[safe: 6] ?? nil) ?? "NO ACTION",
                onUpdate: (row[safe: 7] ?? nil) ?? "NO ACTION"
            )
            grouped[tableName, default: []].append(fk)
        }
        return grouped
    }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        let dbName = _activeDatabase
        let escapedDb = dbName.replacingOccurrences(of: "'", with: "''")
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")

        let query = """
            SELECT TABLE_ROWS
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = '\(escapedDb)'
              AND TABLE_NAME = '\(escapedTable)'
            """

        let result = try await execute(query: query)
        guard let firstRow = result.rows.first,
              let value = firstRow[safe: 0] ?? nil,
              let count = Int(value)
        else { return nil }

        return count
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let safeTable = table.replacingOccurrences(of: "`", with: "``")
        let result = try await execute(query: "SHOW CREATE TABLE `\(safeTable)`")

        guard let firstRow = result.rows.first,
              let ddl = firstRow[safe: 1] ?? nil
        else {
            throw MariaDBPluginError(code: 0, message: "Failed to fetch DDL for table '\(table)'", sqlState: nil)
        }

        return ddl.hasSuffix(";") ? ddl : ddl + ";"
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        let safeView = view.replacingOccurrences(of: "`", with: "``")
        let result = try await execute(query: "SHOW CREATE VIEW `\(safeView)`")

        guard let firstRow = result.rows.first,
              let ddl = firstRow[safe: 1] ?? nil
        else {
            throw MariaDBPluginError(code: 0, message: "Failed to fetch definition for view '\(view)'", sqlState: nil)
        }

        return ddl
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")
        let result = try await execute(query: "SHOW TABLE STATUS WHERE Name = '\(escapedTable)'")

        guard let row = result.rows.first else {
            return PluginTableMetadata(tableName: table)
        }

        let engine = row[safe: 1] ?? nil
        let rowCount = (row[safe: 4] ?? nil).flatMap { Int64($0) }
        let dataSize = (row[safe: 6] ?? nil).flatMap { Int64($0) }
        let indexSize = (row[safe: 8] ?? nil).flatMap { Int64($0) }
        let comment = row[safe: 17] ?? nil

        let totalSize: Int64? = {
            guard let data = dataSize, let index = indexSize else { return nil }
            return data + index
        }()

        return PluginTableMetadata(
            tableName: table,
            dataSize: dataSize,
            indexSize: indexSize,
            totalSize: totalSize,
            rowCount: rowCount,
            comment: comment?.isEmpty == true ? nil : comment,
            engine: engine
        )
    }

    // MARK: - Streaming

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        guard let conn = mariadbConnection else {
            return AsyncThrowingStream { $0.finish(throwing: MariaDBPluginError.notConnected) }
        }
        let baseQuery = stripLimitOffset(from: query)
        return conn.streamQuery(baseQuery)
    }

    // MARK: - Paginated Query Support

    func fetchRowCount(query: String) async throws -> Int {
        let baseQuery = stripLimitOffset(from: query)
        let countQuery = "SELECT COUNT(*) AS cnt FROM (\(baseQuery)) AS __count_subquery__"
        let result = try await execute(query: countQuery)

        guard let firstRow = result.rows.first,
              let countStr = firstRow[safe: 0] ?? nil,
              let count = Int(countStr)
        else { return 0 }

        return count
    }

    func fetchRows(query: String, offset: Int, limit: Int) async throws -> PluginQueryResult {
        let baseQuery = stripLimitOffset(from: query)
        let paginatedQuery = "\(baseQuery) LIMIT \(limit) OFFSET \(offset)"
        return try await execute(query: paginatedQuery)
    }

    // MARK: - Database Operations

    func fetchDatabases() async throws -> [String] {
        let result = try await execute(query: "SHOW DATABASES")
        return result.rows.compactMap { row in row[safe: 0] ?? nil }
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        let escapedDb = database.replacingOccurrences(of: "'", with: "''")

        let query = """
            SELECT COUNT(*), COALESCE(SUM(DATA_LENGTH + INDEX_LENGTH), 0)
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = '\(escapedDb)'
        """
        let result = try await execute(query: query)
        let row = result.rows.first
        let tableCount = Int((row?[safe: 0] ?? nil) ?? "0") ?? 0
        let sizeBytes = Int64((row?[safe: 1] ?? nil) ?? "0") ?? 0

        let systemDatabases = ["information_schema", "mysql", "performance_schema", "sys"]
        let isSystem = systemDatabases.contains(database)

        return PluginDatabaseMetadata(
            name: database,
            tableCount: tableCount,
            sizeBytes: sizeBytes,
            isSystemDatabase: isSystem
        )
    }

    func fetchAllDatabaseMetadata() async throws -> [PluginDatabaseMetadata] {
        let systemDatabases = ["information_schema", "mysql", "performance_schema", "sys"]

        let query = """
            SELECT TABLE_SCHEMA, COUNT(*), COALESCE(SUM(DATA_LENGTH + INDEX_LENGTH), 0)
            FROM information_schema.TABLES
            GROUP BY TABLE_SCHEMA
        """
        let result = try await execute(query: query)

        var metadataByName: [String: PluginDatabaseMetadata] = [:]
        for row in result.rows {
            guard let dbName = row[safe: 0] ?? nil else { continue }
            let tableCount = Int((row[safe: 1] ?? nil) ?? "0") ?? 0
            let sizeBytes = Int64((row[safe: 2] ?? nil) ?? "0") ?? 0
            let isSystem = systemDatabases.contains(dbName)

            metadataByName[dbName] = PluginDatabaseMetadata(
                name: dbName, tableCount: tableCount,
                sizeBytes: sizeBytes, isSystemDatabase: isSystem
            )
        }

        let allDatabases = try await fetchDatabases()
        return allDatabases.map { dbName in
            metadataByName[dbName] ?? PluginDatabaseMetadata(name: dbName)
        }
    }

    func createDatabase(name: String, charset: String, collation: String?) async throws {
        let escapedName = name.replacingOccurrences(of: "`", with: "``")

        let validCharsets = ["utf8mb4", "utf8mb3", "utf8", "latin1", "ascii",
                              "binary", "utf16", "utf32", "cp1251", "big5",
                              "euckr", "gb2312", "gbk", "sjis"]
        guard validCharsets.contains(charset) else {
            throw MariaDBPluginError(code: 0, message: "Invalid character set: \(charset)", sqlState: nil)
        }

        var query = "CREATE DATABASE `\(escapedName)` CHARACTER SET \(charset)"

        if let collation = collation {
            let allowedChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
            let isSafe = collation.unicodeScalars.allSatisfy { allowedChars.contains($0) }
            guard collation.hasPrefix(charset), isSafe else {
                throw MariaDBPluginError(code: 0, message: "Invalid collation for charset", sqlState: nil)
            }
            query += " COLLATE \(collation)"
        }

        _ = try await execute(query: query)
    }

    // MARK: - Database Switching

    func switchDatabase(to database: String) async throws {
        let escaped = database.replacingOccurrences(of: "`", with: "``")
        _ = try await execute(query: "USE `\(escaped)`")
        _activeDatabase = database
    }

    // MARK: - Query Timeout

    func applyQueryTimeout(_ seconds: Int) async throws {
        guard seconds > 0 else { return }
        do {
            if isMariaDB {
                _ = try await execute(query: "SET SESSION max_statement_time = \(seconds)")
            } else {
                let ms = seconds * 1_000
                _ = try await execute(query: "SET SESSION max_execution_time = \(ms)")
            }
        } catch {
            Self.logger.warning("Failed to set query timeout: \(error.localizedDescription)")
        }
    }

    // MARK: - EXPLAIN

    func buildExplainQuery(_ sql: String) -> String? {
        "EXPLAIN \(sql)"
    }

    // MARK: - Maintenance

    func supportedMaintenanceOperations() -> [String]? {
        ["OPTIMIZE TABLE", "ANALYZE TABLE", "CHECK TABLE", "REPAIR TABLE"]
    }

    func maintenanceStatements(operation: String, table: String?, schema: String?, options: [String: String]) -> [String]? {
        guard let table else { return nil }
        let quoted = quoteIdentifier(table)
        switch operation {
        case "OPTIMIZE TABLE": return ["OPTIMIZE TABLE \(quoted)"]
        case "ANALYZE TABLE": return ["ANALYZE TABLE \(quoted)"]
        case "CHECK TABLE":
            let mode = options["mode"] ?? "MEDIUM"
            return ["CHECK TABLE \(quoted) \(mode)"]
        case "REPAIR TABLE": return ["REPAIR TABLE \(quoted)"]
        default: return nil
        }
    }

    // MARK: - Create Table DDL

    func generateCreateTableSQL(definition: PluginCreateTableDefinition) -> String? {
        let tableName = quoteIdentifier(definition.tableName)
        let ifNotExists = definition.ifNotExists ? " IF NOT EXISTS" : ""

        var parts: [String] = []

        for column in definition.columns {
            parts.append(buildColumnDefinitionSQL(column))
        }

        var pkCols = definition.primaryKeyColumns
        if pkCols.isEmpty {
            pkCols = definition.columns.filter { $0.autoIncrement }.map(\.name)
        }
        if !pkCols.isEmpty {
            let quoted = pkCols.map { quoteIdentifier($0) }.joined(separator: ", ")
            parts.append("PRIMARY KEY (\(quoted))")
        }

        for index in definition.indexes {
            parts.append(buildIndexDefinitionSQL(index))
        }

        for fk in definition.foreignKeys {
            parts.append(buildForeignKeyDefinitionSQL(fk))
        }

        var sql = "CREATE TABLE\(ifNotExists) \(tableName) (\n"
        sql += parts.map { "    \($0)" }.joined(separator: ",\n")
        sql += "\n)"

        var tableOptions: [String] = []
        if let engine = definition.engine, !engine.isEmpty {
            tableOptions.append("ENGINE=\(engine)")
        }
        if let charset = definition.charset, !charset.isEmpty {
            tableOptions.append("DEFAULT CHARSET=\(charset)")
        }
        if let collation = definition.collation, !collation.isEmpty {
            tableOptions.append("COLLATE=\(collation)")
        }

        if !tableOptions.isEmpty {
            sql += " " + tableOptions.joined(separator: " ")
        }

        sql += ";"
        return sql
    }

    private func buildColumnDefinitionSQL(_ column: PluginColumnDefinition) -> String {
        var def = "\(quoteIdentifier(column.name)) \(column.dataType)"

        if column.unsigned {
            def += " UNSIGNED"
        }
        if column.isNullable {
            def += " NULL"
        } else {
            def += " NOT NULL"
        }
        if let defaultValue = column.defaultValue {
            let upper = defaultValue.uppercased()
            if upper == "NULL" || upper == "CURRENT_TIMESTAMP" || upper == "CURRENT_TIMESTAMP()"
                || defaultValue.hasPrefix("'") {
                def += " DEFAULT \(defaultValue)"
            } else if Int64(defaultValue) != nil || Double(defaultValue) != nil {
                def += " DEFAULT \(defaultValue)"
            } else {
                def += " DEFAULT '\(escapeStringLiteral(defaultValue))'"
            }
        }
        if column.autoIncrement {
            def += " AUTO_INCREMENT"
        }
        if let onUpdate = column.onUpdate, !onUpdate.isEmpty {
            let upper = onUpdate.uppercased()
            if upper == "CURRENT_TIMESTAMP" || upper == "CURRENT_TIMESTAMP()"
                || upper.hasPrefix("CURRENT_TIMESTAMP(") {
                def += " ON UPDATE \(onUpdate)"
            }
        }
        if let comment = column.comment, !comment.isEmpty {
            def += " COMMENT '\(escapeStringLiteral(comment))'"
        }

        return def
    }

    private func buildIndexDefinitionSQL(_ index: PluginIndexDefinition) -> String {
        let cols = index.columns.map { quoteIdentifier($0) }.joined(separator: ", ")
        var def = ""

        let upperType = index.indexType?.uppercased() ?? ""
        if upperType == "FULLTEXT" {
            def += "FULLTEXT INDEX"
        } else if upperType == "SPATIAL" {
            def += "SPATIAL INDEX"
        } else if index.isUnique {
            def += "UNIQUE INDEX"
        } else {
            def += "INDEX"
        }

        def += " \(quoteIdentifier(index.name)) (\(cols))"

        if upperType == "BTREE" || upperType == "HASH" {
            def += " USING \(upperType)"
        }

        return def
    }

    private func buildForeignKeyDefinitionSQL(_ fk: PluginForeignKeyDefinition) -> String {
        let cols = fk.columns.map { quoteIdentifier($0) }.joined(separator: ", ")
        let refCols = fk.referencedColumns.map { quoteIdentifier($0) }.joined(separator: ", ")
        let refTable = quoteIdentifier(fk.referencedTable)

        var def = "CONSTRAINT \(quoteIdentifier(fk.name)) FOREIGN KEY (\(cols)) REFERENCES \(refTable) (\(refCols))"

        let onDelete = fk.onDelete.uppercased()
        if onDelete != "NO ACTION" {
            def += " ON DELETE \(onDelete)"
        }

        let onUpdate = fk.onUpdate.uppercased()
        if onUpdate != "NO ACTION" {
            def += " ON UPDATE \(onUpdate)"
        }

        return def
    }

    // MARK: - Definition SQL (clipboard copy)

    func generateColumnDefinitionSQL(column: PluginColumnDefinition) -> String? {
        buildColumnDefinitionSQL(column)
    }

    func generateIndexDefinitionSQL(index: PluginIndexDefinition, tableName: String?) -> String? {
        buildIndexDefinitionSQL(index)
    }

    func generateForeignKeyDefinitionSQL(fk: PluginForeignKeyDefinition) -> String? {
        buildForeignKeyDefinitionSQL(fk)
    }

    // MARK: - Column Reorder DDL

    func generateMoveColumnSQL(table: String, column: PluginColumnDefinition, afterColumn: String?) -> String? {
        let tableName = quoteIdentifier(table)
        let colName = quoteIdentifier(column.name)

        var def = "\(column.dataType)"
        if column.unsigned {
            def += " UNSIGNED"
        }
        if column.isNullable {
            def += " NULL"
        } else {
            def += " NOT NULL"
        }
        if let defaultValue = column.defaultValue {
            let upper = defaultValue.uppercased()
            if upper == "NULL" || upper == "CURRENT_TIMESTAMP" || upper == "CURRENT_TIMESTAMP()"
                || defaultValue.hasPrefix("'") {
                def += " DEFAULT \(defaultValue)"
            } else if Int64(defaultValue) != nil || Double(defaultValue) != nil {
                def += " DEFAULT \(defaultValue)"
            } else {
                def += " DEFAULT '\(escapeStringLiteral(defaultValue))'"
            }
        }
        if column.autoIncrement {
            def += " AUTO_INCREMENT"
        }
        if let onUpdate = column.onUpdate, !onUpdate.isEmpty {
            let upper = onUpdate.uppercased()
            if upper == "CURRENT_TIMESTAMP" || upper == "CURRENT_TIMESTAMP()" || upper.hasPrefix("CURRENT_TIMESTAMP(") {
                def += " ON UPDATE \(onUpdate)"
            }
        }
        if let comment = column.comment, !comment.isEmpty {
            def += " COMMENT '\(escapeStringLiteral(comment))'"
        }

        let position: String
        if let afterCol = afterColumn {
            position = "AFTER \(quoteIdentifier(afterCol))"
        } else {
            position = "FIRST"
        }

        return "ALTER TABLE \(tableName) MODIFY COLUMN \(colName) \(def) \(position)"
    }

    // MARK: - View Templates

    func createViewTemplate() -> String? {
        "CREATE VIEW view_name AS\nSELECT column1, column2\nFROM table_name\nWHERE condition;"
    }

    func editViewFallbackTemplate(viewName: String) -> String? {
        let quoted = quoteIdentifier(viewName)
        return "ALTER VIEW \(quoted) AS\nSELECT * FROM table_name;"
    }

    func castColumnToText(_ column: String) -> String {
        "CAST(\(column) AS CHAR)"
    }

    // MARK: - Foreign Key Checks

    func foreignKeyDisableStatements() -> [String]? {
        ["SET FOREIGN_KEY_CHECKS=0"]
    }

    func foreignKeyEnableStatements() -> [String]? {
        ["SET FOREIGN_KEY_CHECKS=1"]
    }

    // MARK: - All Tables Metadata

    func allTablesMetadataSQL(schema: String?) -> String? {
        """
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
        WHERE TABLE_SCHEMA = DATABASE()
        ORDER BY TABLE_NAME
        """
    }

    // MARK: - Private Helpers

    private func extractTableName(from query: String) -> String? {
        guard let regex = Self.tableNameRegex,
              let match = regex.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)),
              let range = Range(match.range(at: 1), in: query)
        else { return nil }
        return String(query[range])
    }

    private func fetchColumnNames(for tableName: String) async throws -> [String] {
        let safeName = tableName.replacingOccurrences(of: "`", with: "``")
        let result = try await execute(query: "DESCRIBE `\(safeName)`")

        var columns: [String] = []
        for row in result.rows {
            if let columnName = row[safe: 0] ?? nil {
                columns.append(columnName)
            }
        }
        return columns
    }

    private func stripLimitOffset(from query: String) -> String {
        var result = query

        if let regex = Self.limitRegex {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }

        if let regex = Self.offsetRegex {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
