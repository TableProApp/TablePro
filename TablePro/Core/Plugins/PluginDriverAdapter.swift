//
//  PluginDriverAdapter.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

final class PluginDriverAdapter: DatabaseDriver, SchemaSwitchable {
    let connection: DatabaseConnection
    private(set) var status: ConnectionStatus = .disconnected
    private let pluginDriver: any PluginDatabaseDriver
    private var columnTypeCache: [String: ColumnType] = [:]
    private let classifier = ColumnTypeClassifier()

    var serverVersion: String? { pluginDriver.serverVersion }
    var parameterStyle: ParameterStyle { pluginDriver.parameterStyle }

    func pluginGenerateStatements(
        table: String,
        columns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [String?]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [String?])]? {
        pluginDriver.generateStatements(
            table: table, columns: columns, changes: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: deletedRowIndices,
            insertedRowIndices: insertedRowIndices
        )
    }

    /// The underlying plugin driver, exposed for DDL schema generation delegation.
    var schemaPluginDriver: any PluginDatabaseDriver { pluginDriver }

    var queryBuildingPluginDriver: (any PluginDatabaseDriver)? {
        // Expose plugin driver for query building dispatch if it implements the hooks.
        // SQL drivers without custom pagination (MySQL, PostgreSQL, etc.) return nil
        // from buildBrowseQuery and use standard SQL query rewriting instead.
        guard pluginDriver.buildBrowseQuery(
            table: "_probe", sortColumns: [], columns: [], limit: 1, offset: 0
        ) != nil else {
            return nil
        }
        return pluginDriver
    }
    var currentSchema: String { pluginDriver.currentSchema ?? connection.username }
    var escapedSchema: String { pluginDriver.escapeStringLiteral(currentSchema) }

    private static let logger = Logger(subsystem: "com.TablePro", category: "PluginDriverAdapter")

    init(connection: DatabaseConnection, pluginDriver: any PluginDatabaseDriver) {
        self.connection = connection
        self.pluginDriver = pluginDriver
    }

    // MARK: - Connection Management

    func connect() async throws {
        status = .connecting
        do {
            try await pluginDriver.connect()
            status = .connected
        } catch {
            status = .error(error.localizedDescription)
            throw error
        }
    }

    func disconnect() {
        pluginDriver.disconnect()
        status = .disconnected
    }

    func applyQueryTimeout(_ seconds: Int) async throws {
        try await pluginDriver.applyQueryTimeout(seconds)
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> QueryResult {
        let pluginResult = try await pluginDriver.execute(query: query)
        return mapQueryResult(pluginResult)
    }

    func executeParameterized(query: String, parameters: [Any?]) async throws -> QueryResult {
        let stringParams = parameters.map { param -> String? in
            guard let p = param else { return nil }
            return String(describing: p)
        }
        let pluginResult = try await pluginDriver.executeParameterized(query: query, parameters: stringParams)
        return mapQueryResult(pluginResult)
    }

    func fetchRowCount(query: String) async throws -> Int {
        try await pluginDriver.fetchRowCount(query: query)
    }

    func fetchRows(query: String, offset: Int, limit: Int) async throws -> QueryResult {
        let pluginResult = try await pluginDriver.fetchRows(query: query, offset: offset, limit: limit)
        return mapQueryResult(pluginResult)
    }

    // MARK: - Schema Operations

    func fetchTables() async throws -> [TableInfo] {
        let pluginTables = try await pluginDriver.fetchTables(schema: pluginDriver.currentSchema)
        return pluginTables.map { table in
            let tableType: TableInfo.TableType = switch table.type.lowercased() {
            case "view": .view
            case "system table": .systemTable
            default: .table
            }
            return TableInfo(name: table.name, type: tableType, rowCount: table.rowCount)
        }
    }

    func fetchColumns(table: String) async throws -> [ColumnInfo] {
        let pluginColumns = try await pluginDriver.fetchColumns(table: table, schema: pluginDriver.currentSchema)
        return pluginColumns.map { col in
            ColumnInfo(
                name: col.name,
                dataType: col.dataType,
                isNullable: col.isNullable,
                isPrimaryKey: col.isPrimaryKey,
                defaultValue: col.defaultValue,
                extra: col.extra,
                charset: col.charset,
                collation: col.collation,
                comment: col.comment
            )
        }
    }

    func fetchIndexes(table: String) async throws -> [IndexInfo] {
        let pluginIndexes = try await pluginDriver.fetchIndexes(table: table, schema: pluginDriver.currentSchema)
        return pluginIndexes.map { idx in
            IndexInfo(
                name: idx.name,
                columns: idx.columns,
                isUnique: idx.isUnique,
                isPrimary: idx.isPrimary,
                type: idx.type
            )
        }
    }

    func fetchForeignKeys(table: String) async throws -> [ForeignKeyInfo] {
        let pluginFKs = try await pluginDriver.fetchForeignKeys(table: table, schema: pluginDriver.currentSchema)
        return pluginFKs.map { fk in
            ForeignKeyInfo(
                name: fk.name,
                column: fk.column,
                referencedTable: fk.referencedTable,
                referencedColumn: fk.referencedColumn,
                onDelete: fk.onDelete,
                onUpdate: fk.onUpdate
            )
        }
    }

    func fetchApproximateRowCount(table: String) async throws -> Int? {
        try await pluginDriver.fetchApproximateRowCount(table: table, schema: pluginDriver.currentSchema)
    }

    func fetchTableDDL(table: String) async throws -> String {
        try await pluginDriver.fetchTableDDL(table: table, schema: pluginDriver.currentSchema)
    }

    func fetchDependentTypes(forTable table: String) async throws -> [(name: String, labels: [String])] {
        try await pluginDriver.fetchDependentTypes(table: table, schema: pluginDriver.currentSchema)
    }

    func fetchDependentSequences(forTable table: String) async throws -> [(name: String, ddl: String)] {
        try await pluginDriver.fetchDependentSequences(table: table, schema: pluginDriver.currentSchema)
    }

    func fetchViewDefinition(view: String) async throws -> String {
        try await pluginDriver.fetchViewDefinition(view: view, schema: pluginDriver.currentSchema)
    }

    func fetchTableMetadata(tableName: String) async throws -> TableMetadata {
        let pluginMeta = try await pluginDriver.fetchTableMetadata(
            table: tableName,
            schema: pluginDriver.currentSchema
        )
        return TableMetadata(
            tableName: pluginMeta.tableName,
            dataSize: pluginMeta.dataSize,
            indexSize: pluginMeta.indexSize,
            totalSize: pluginMeta.totalSize,
            avgRowLength: nil,
            rowCount: pluginMeta.rowCount,
            comment: pluginMeta.comment,
            engine: pluginMeta.engine,
            collation: nil,
            createTime: nil,
            updateTime: nil
        )
    }

    func fetchDatabases() async throws -> [String] {
        try await pluginDriver.fetchDatabases()
    }

    func fetchSchemas() async throws -> [String] {
        try await pluginDriver.fetchSchemas()
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> DatabaseMetadata {
        let pluginMeta = try await pluginDriver.fetchDatabaseMetadata(database)
        return DatabaseMetadata(
            id: pluginMeta.name,
            name: pluginMeta.name,
            tableCount: pluginMeta.tableCount,
            sizeBytes: pluginMeta.sizeBytes,
            lastAccessed: nil,
            isSystemDatabase: pluginMeta.isSystemDatabase,
            icon: pluginMeta.isSystemDatabase ? "gearshape.fill" : "cylinder.fill"
        )
    }

    func createDatabase(name: String, charset: String, collation: String?) async throws {
        try await pluginDriver.createDatabase(name: name, charset: charset, collation: collation)
    }

    // MARK: - Batch Operations

    func fetchAllColumns() async throws -> [String: [ColumnInfo]] {
        let pluginResult = try await pluginDriver.fetchAllColumns(schema: pluginDriver.currentSchema)
        var result: [String: [ColumnInfo]] = [:]
        for (table, cols) in pluginResult {
            result[table] = cols.map { col in
                ColumnInfo(name: col.name, dataType: col.dataType, isNullable: col.isNullable,
                           isPrimaryKey: col.isPrimaryKey, defaultValue: col.defaultValue,
                           extra: col.extra, charset: col.charset, collation: col.collation, comment: col.comment)
            }
        }
        return result
    }

    func fetchAllForeignKeys() async throws -> [String: [ForeignKeyInfo]] {
        let pluginResult = try await pluginDriver.fetchAllForeignKeys(schema: pluginDriver.currentSchema)
        var result: [String: [ForeignKeyInfo]] = [:]
        for (table, fks) in pluginResult {
            result[table] = fks.map { fk in
                ForeignKeyInfo(name: fk.name, column: fk.column, referencedTable: fk.referencedTable,
                               referencedColumn: fk.referencedColumn, onDelete: fk.onDelete, onUpdate: fk.onUpdate)
            }
        }
        return result
    }

    func fetchAllDatabaseMetadata() async throws -> [DatabaseMetadata] {
        let pluginResult = try await pluginDriver.fetchAllDatabaseMetadata()
        return pluginResult.map { meta in
            DatabaseMetadata(id: meta.name, name: meta.name, tableCount: meta.tableCount,
                             sizeBytes: meta.sizeBytes, lastAccessed: nil,
                             isSystemDatabase: meta.isSystemDatabase,
                             icon: meta.isSystemDatabase ? "gearshape.fill" : "cylinder.fill")
        }
    }

    // MARK: - Query Cancellation

    func cancelQuery() throws {
        try pluginDriver.cancelQuery()
    }

    // MARK: - Transaction Management

    func beginTransaction() async throws {
        try await pluginDriver.beginTransaction()
    }

    func commitTransaction() async throws {
        try await pluginDriver.commitTransaction()
    }

    func rollbackTransaction() async throws {
        try await pluginDriver.rollbackTransaction()
    }

    // MARK: - Schema Switching

    func switchSchema(to schema: String) async throws {
        try await pluginDriver.switchSchema(to: schema)
    }

    // MARK: - Database Switching

    func switchDatabase(to database: String) async throws {
        try await pluginDriver.switchDatabase(to: database)
    }

    // MARK: - DDL Schema Generation

    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        pluginDriver.generateAddColumnSQL(table: table, column: column)
    }

    func generateModifyColumnSQL(
        table: String,
        oldColumn: PluginColumnDefinition,
        newColumn: PluginColumnDefinition
    ) -> String? {
        pluginDriver.generateModifyColumnSQL(table: table, oldColumn: oldColumn, newColumn: newColumn)
    }

    func generateDropColumnSQL(table: String, columnName: String) -> String? {
        pluginDriver.generateDropColumnSQL(table: table, columnName: columnName)
    }

    func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String? {
        pluginDriver.generateAddIndexSQL(table: table, index: index)
    }

    func generateDropIndexSQL(table: String, indexName: String) -> String? {
        pluginDriver.generateDropIndexSQL(table: table, indexName: indexName)
    }

    func generateAddForeignKeySQL(table: String, fk: PluginForeignKeyDefinition) -> String? {
        pluginDriver.generateAddForeignKeySQL(table: table, fk: fk)
    }

    func generateDropForeignKeySQL(table: String, constraintName: String) -> String? {
        pluginDriver.generateDropForeignKeySQL(table: table, constraintName: constraintName)
    }

    func generateModifyPrimaryKeySQL(table: String, oldColumns: [String], newColumns: [String], constraintName: String?) -> [String]? {
        pluginDriver.generateModifyPrimaryKeySQL(table: table, oldColumns: oldColumns, newColumns: newColumns, constraintName: constraintName)
    }

    // MARK: - Table Operations

    func truncateTableStatements(table: String, schema: String?, cascade: Bool) -> [String] {
        if let stmts = pluginDriver.truncateTableStatements(table: table, schema: schema, cascade: cascade) {
            return stmts
        }
        let name = qualifiedName(table, schema: schema)
        let cascadeSuffix = cascade ? " CASCADE" : ""
        return ["TRUNCATE TABLE \(name)\(cascadeSuffix)"]
    }

    func dropObjectStatement(name: String, objectType: String, schema: String?, cascade: Bool) -> String {
        if let stmt = pluginDriver.dropObjectStatement(name: name, objectType: objectType, schema: schema, cascade: cascade) {
            return stmt
        }
        let qualName = qualifiedName(name, schema: schema)
        let cascadeSuffix = cascade ? " CASCADE" : ""
        return "DROP \(objectType) \(qualName)\(cascadeSuffix)"
    }

    func foreignKeyDisableStatements() -> [String]? {
        pluginDriver.foreignKeyDisableStatements()
    }

    func foreignKeyEnableStatements() -> [String]? {
        pluginDriver.foreignKeyEnableStatements()
    }

    // MARK: - All Tables Metadata SQL

    func allTablesMetadataSQL(schema: String?) -> String? {
        pluginDriver.allTablesMetadataSQL(schema: schema)
    }

    // MARK: - EXPLAIN

    func buildExplainQuery(_ sql: String) -> String? {
        pluginDriver.buildExplainQuery(sql)
    }

    // MARK: - View Templates

    func createViewTemplate() -> String? {
        pluginDriver.createViewTemplate()
    }

    func editViewFallbackTemplate(viewName: String) -> String? {
        pluginDriver.editViewFallbackTemplate(viewName: viewName)
    }

    func castColumnToText(_ column: String) -> String {
        pluginDriver.castColumnToText(column)
    }

    // MARK: - Identifier Quoting

    func quoteIdentifier(_ name: String) -> String {
        pluginDriver.quoteIdentifier(name)
    }

    func escapeStringLiteral(_ value: String) -> String {
        pluginDriver.escapeStringLiteral(value)
    }

    // MARK: - Private Helpers

    private func qualifiedName(_ name: String, schema: String?) -> String {
        let quoted = pluginDriver.quoteIdentifier(name)
        guard let schema, !schema.isEmpty else { return quoted }
        return "\(pluginDriver.quoteIdentifier(schema)).\(quoted)"
    }

    // MARK: - Result Mapping

    private func mapQueryResult(_ pluginResult: PluginQueryResult) -> QueryResult {
        let columnTypes = pluginResult.columnTypeNames.map { mapColumnType(rawTypeName: $0) }
        var result = QueryResult(
            columns: pluginResult.columns,
            columnTypes: columnTypes,
            rows: pluginResult.rows,
            rowsAffected: pluginResult.rowsAffected,
            executionTime: pluginResult.executionTime,
            error: nil
        )
        result.isTruncated = pluginResult.isTruncated
        return result
    }

    private func mapColumnType(rawTypeName: String) -> ColumnType {
        if let cached = columnTypeCache[rawTypeName] { return cached }
        let result = classifier.classify(rawTypeName: rawTypeName)
        columnTypeCache[rawTypeName] = result
        return result
    }
}
