//
//  PluginDriverAdapter.swift
//  TablePro
//

import Foundation
import os
import TableProNumberFormatting
import TableProPluginKit

final class PluginDriverAdapter: DatabaseDriver, SchemaSwitchable, DatabaseReporting {
    private struct State {
        var status: ConnectionStatus = .disconnected
        var columnTypeCache: [String: ColumnType] = [:]
    }

    let connection: DatabaseConnection
    private let pluginDriver: any PluginDatabaseDriver
    private let classifier = ColumnTypeClassifier()
    private let state = OSAllocatedUnfairLock(initialState: State())

    var status: ConnectionStatus {
        state.withLock { $0.status }
    }

    var serverVersion: String? { pluginDriver.serverVersion }
    var parameterStyle: ParameterStyle { pluginDriver.parameterStyle }

    func pluginGenerateStatements(
        table: String,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [String?]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [String?])]? {
        let pluginRowData = insertedRowData.mapValues { row in
            row.map(PluginCellValue.fromOptional)
        }
        let result = pluginDriver.generateStatements(
            table: table, columns: columns, primaryKeyColumns: primaryKeyColumns, changes: changes,
            insertedRowData: pluginRowData,
            deletedRowIndices: deletedRowIndices,
            insertedRowIndices: insertedRowIndices
        )
        return result?.map { (statement: $0.statement, parameters: $0.parameters.map { $0.asText }) }
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
    var currentSchema: String? {
        guard pluginDriver.supportsSchemas else { return nil }
        return pluginDriver.currentSchema
    }

    var escapedSchema: String? {
        guard let schema = currentSchema else { return nil }
        return pluginDriver.escapeStringLiteral(schema)
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "PluginDriverAdapter")

    private static let iso8601Formatter = OSAllocatedUnfairLock(
        uncheckedState: {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
    )

    static func cellValue(for parameter: Any?) -> PluginCellValue {
        guard let parameter else { return .null }
        if let data = parameter as? Data { return .bytes(data) }
        if let f = parameter as? Float {
            guard f.isFinite else { return .null }
            return .text(NumberText.text(for: f))
        }
        if let f = parameter as? any BinaryFloatingPoint {
            let d = Double(f)
            guard d.isFinite else { return .null }
            return .text(NumberText.text(for: d))
        }
        return .text(stringValue(for: parameter))
    }

    private static func stringValue(for parameter: Any) -> String {
        switch parameter {
        case let s as String:
            return s
        case let b as Bool:
            return b ? "1" : "0"
        case let i as any BinaryInteger:
            return String(i)
        case let f as any BinaryFloatingPoint:
            return NumberText.text(for: Double(f))
        case let d as Date:
            return Self.iso8601Formatter.withLockUnchecked { $0.string(from: d) }
        case let data as Data:
            return data.hexEncoded
        case let uuid as UUID:
            return uuid.uuidString
        default:
            return String(describing: parameter)
        }
    }

    init(connection: DatabaseConnection, pluginDriver: any PluginDatabaseDriver) {
        self.connection = connection
        self.pluginDriver = pluginDriver
    }

    // MARK: - Connection Management

    func connect() async throws {
        try await connectReporting(stage: { _ in })
    }

    func connectReporting(stage report: @escaping ConnectionStageReporter) async throws {
        state.withLock { $0.status = .connecting }
        do {
            try await pluginDriver.connect(reportingStage: report)
            state.withLock { $0.status = .connected }
        } catch {
            state.withLock { $0.status = .error(error.localizedDescription) }
            throw error
        }
    }

    func disconnect() {
        pluginDriver.disconnect()
        state.withLock { $0.status = .disconnected }
    }

    func ping() async throws {
        try await pluginDriver.ping()
    }

    func applyQueryTimeout(_ seconds: Int) async throws {
        try await pluginDriver.applyQueryTimeout(seconds)
    }

    func resolveQueryCompletionProfile(
        databaseTypeId: String,
        base: QueryCompletionProfile
    ) async throws -> QueryCompletionProfile {
        try await pluginDriver.resolveQueryCompletionProfile(
            databaseTypeId: databaseTypeId,
            base: base
        )
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> QueryResult {
        let pluginResult = try await pluginDriver.execute(query: query)
        return mapQueryResult(pluginResult)
    }

    func executeParameterized(query: String, parameters: [Any?]) async throws -> QueryResult {
        let cellParams: [PluginCellValue] = parameters.map(Self.cellValue(for:))
        let pluginResult = try await pluginDriver.executeParameterized(query: query, parameters: cellParams)
        return mapQueryResult(pluginResult)
    }

    func executeUserQuery(query: String, rowCap: Int?, parameters: [Any?]?) async throws -> QueryResult {
        let cellParams: [PluginCellValue]?
        if let parameters {
            cellParams = parameters.map(Self.cellValue(for:))
        } else {
            cellParams = nil
        }
        let pluginResult = try await pluginDriver.executeUserQuery(
            query: query,
            rowCap: rowCap,
            parameters: cellParams
        )
        return mapQueryResult(pluginResult)
    }

    func executeBoundedQuery(query: String, rowCap: Int) async throws -> QueryResult? {
        guard let pluginResult = try await pluginDriver.executeBoundedQuery(query: query, rowCap: rowCap) else {
            return nil
        }
        return mapQueryResult(pluginResult)
    }

    // MARK: - Schema Operations

    func fetchTables() async throws -> [TableInfo] {
        try await fetchTables(schema: nil)
    }

    func fetchTables(schema: String?) async throws -> [TableInfo] {
        let resolvedSchema = schema ?? pluginDriver.currentSchema
        let pluginTables = try await pluginDriver.fetchTables(schema: resolvedSchema)
        return pluginTables.map { mapPluginTable($0, schemaFallback: resolvedSchema) }
    }

    func fetchPartitions(table: String, schema: String?) async throws -> [TableInfo] {
        let resolvedSchema = schema ?? pluginDriver.currentSchema
        let pluginTables = try await pluginDriver.fetchPartitions(table: table, schema: resolvedSchema)
        return pluginTables.map { mapPluginTable($0, schemaFallback: resolvedSchema) }
    }

    private func mapPluginTable(_ table: PluginTableInfo, schemaFallback: String?) -> TableInfo {
        let tableType: TableInfo.TableType
        switch table.type.lowercased() {
        case "table", "base table", "prefix":
            tableType = .table
        case "partitioned table", "partitioned_table":
            tableType = .partitionedTable
        case "view":
            tableType = .view
        case "materialized view", "materialized_view":
            tableType = .materializedView
        case "foreign table", "foreign_table":
            tableType = .foreignTable
        case "system table", "system base table", "system view":
            tableType = .systemTable
        case "external table", "external_table":
            tableType = .externalTable
        default:
            Self.logger.warning("Unknown plugin table type \"\(table.type, privacy: .public)\" for \"\(table.name, privacy: .public)\"; defaulting to .table")
            tableType = .table
        }
        return TableInfo(
            name: table.name,
            type: tableType,
            rowCount: table.rowCount,
            schema: table.schema ?? schemaFallback,
            comment: table.comment
        )
    }

    func fetchColumns(table: String) async throws -> [ColumnInfo] {
        let pluginColumns = try await pluginDriver.fetchColumns(table: table, schema: pluginDriver.currentSchema)
        return mapPluginColumns(pluginColumns)
    }

    func fetchColumns(table: String, schema: String?) async throws -> [ColumnInfo] {
        let pluginColumns = try await pluginDriver.fetchColumns(table: table, schema: schema ?? pluginDriver.currentSchema)
        return mapPluginColumns(pluginColumns)
    }

    private func mapPluginColumns(_ pluginColumns: [PluginColumnInfo]) -> [ColumnInfo] {
        pluginColumns.map { col in
            ColumnInfo(
                name: col.name,
                dataType: col.dataType,
                isNullable: col.isNullable,
                isPrimaryKey: col.isPrimaryKey,
                defaultValue: col.defaultValue,
                extra: col.extra,
                charset: col.charset,
                collation: col.collation,
                comment: col.comment,
                isGenerated: col.isGenerated,
                allowedValues: col.allowedValues,
                generationExpression: col.generationExpression,
                generationKind: col.generationKind
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
                type: idx.type,
                columnPrefixes: idx.columnPrefixes,
                whereClause: idx.whereClause
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
                referencedSchema: fk.referencedSchema,
                onDelete: fk.onDelete,
                onUpdate: fk.onUpdate
            )
        }
    }

    func fetchCheckConstraints(table: String) async throws -> [CheckConstraintInfo] {
        let pluginConstraints = try await pluginDriver.fetchCheckConstraints(
            table: table, schema: pluginDriver.currentSchema
        )
        return pluginConstraints.map { constraint in
            CheckConstraintInfo(
                name: constraint.name,
                expression: constraint.expression,
                columns: constraint.columns,
                isValidated: constraint.isValidated
            )
        }
    }

    func fetchTriggers(table: String) async throws -> [TriggerInfo] {
        let schema = pluginDriver.currentSchema
        let pluginTriggers = try await pluginDriver.fetchTriggers(table: table, schema: schema)
        return pluginTriggers.map { TriggerInfo($0.adopting(table: table, schema: schema)) }
    }

    func fetchAllTriggers(schema: String?) async throws -> [TriggerInfo] {
        let resolvedSchema = schema ?? pluginDriver.currentSchema
        let pluginTriggers = try await pluginDriver.fetchAllTriggers(schema: resolvedSchema)
        return pluginTriggers.map { TriggerInfo($0.adopting(table: nil, schema: resolvedSchema)) }
    }

    func fetchTriggerDDL(_ trigger: TriggerInfo) async throws -> String {
        try await pluginDriver.fetchTriggerDDL(trigger.pluginTrigger)
    }

    func createTriggerTemplate(table: String) -> String? {
        pluginDriver.createTriggerTemplate(table: table, schema: pluginDriver.currentSchema)
    }

    func fetchTriggerDefinition(name: String, table: String) async throws -> String? {
        try await pluginDriver.fetchTriggerDefinition(name: name, table: table, schema: pluginDriver.currentSchema)
    }

    func generateDropTriggerSQL(name: String, table: String) -> String? {
        pluginDriver.generateDropTriggerSQL(name: name, table: table, schema: pluginDriver.currentSchema)
    }

    var triggerEditUsesReplace: Bool { pluginDriver.triggerEditUsesReplace }

    var supportsTransactionalDDL: Bool { pluginDriver.supportsTransactionalDDL }

    func fetchApproximateRowCount(table: String) async throws -> Int? {
        try await pluginDriver.fetchApproximateRowCount(table: table, schema: pluginDriver.currentSchema)
    }

    func fetchFilteredRowCount(table: String, filters: [TableFilter], logicMode: FilterLogicMode) async throws -> Int? {
        let queryFilters = filters
            .filter { $0.isEnabled && !$0.columnName.isEmpty }
            .map(\.asPluginQueryFilter)
        return try await pluginDriver.fetchFilteredRowCount(
            table: table,
            queryFilters: queryFilters,
            logicMode: logicMode == .and ? "and" : "or"
        )
    }

    func fetchExactRowCount(table: String, filters: [TableFilter], logicMode: FilterLogicMode) async throws -> Int? {
        let queryFilters = filters
            .filter { $0.isEnabled && !$0.columnName.isEmpty }
            .map(\.asPluginQueryFilter)
        return try await pluginDriver.fetchExactRowCount(
            table: table,
            schema: pluginDriver.currentSchema,
            queryFilters: queryFilters,
            logicMode: logicMode == .and ? "and" : "or"
        )
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
            avgRowLength: pluginMeta.avgRowLength,
            rowCount: pluginMeta.rowCount,
            comment: pluginMeta.comment,
            engine: pluginMeta.engine,
            collation: pluginMeta.collation,
            createTime: pluginMeta.createTime,
            updateTime: pluginMeta.updateTime
        )
    }

    func fetchDatabases() async throws -> [String] {
        try await pluginDriver.fetchDatabases()
    }

    func fetchSchemas() async throws -> [String] {
        try await pluginDriver.fetchSchemas()
    }

    func fetchExternalSchemaNames() async throws -> Set<String> {
        try await pluginDriver.fetchExternalSchemaNames()
    }

    func fetchRoutines(schema: String?) async throws -> [RoutineInfo] {
        let resolvedSchema = schema ?? pluginDriver.currentSchema
        do {
            let pluginRoutines = try await pluginDriver.fetchRoutines(schema: resolvedSchema)
            return pluginRoutines.map { RoutineInfo($0.adopting(kind: $0.kind, schema: resolvedSchema)) }
                .sorted { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }
        } catch {
            Self.logger.warning("fetchRoutines failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func fetchRoutineDDL(_ routine: RoutineInfo) async throws -> String {
        try await pluginDriver.fetchRoutineDDL(routine.pluginRoutine)
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

    func createDatabaseFormSpec() async throws -> CreateDatabaseFormSpec? {
        guard let pluginSpec = try await pluginDriver.createDatabaseFormSpec() else { return nil }
        return mapFormSpec(pluginSpec)
    }

    func createDatabase(_ request: CreateDatabaseRequest) async throws {
        let pluginRequest = PluginCreateDatabaseRequest(name: request.name, values: request.values)
        try await pluginDriver.createDatabase(pluginRequest)
    }

    func dropDatabase(name: String) async throws {
        try await pluginDriver.dropDatabase(name: name)
    }

    func dropSchema(name: String) async throws {
        try await pluginDriver.dropSchema(name: name)
    }

    func renameTable(name: String, schema: String?, to newName: String, objectType: String) async throws {
        try await pluginDriver.renameTable(name: name, schema: schema, to: newName, objectType: objectType)
    }

    func renameDatabase(name: String, to newName: String) async throws {
        try await pluginDriver.renameDatabase(name: name, to: newName)
    }

    func renameSchema(name: String, to newName: String) async throws {
        try await pluginDriver.renameSchema(name: name, to: newName)
    }

    func fetchSessionContexts() async throws -> [PluginSessionContext]? {
        try await pluginDriver.fetchSessionContexts()
    }

    func switchSessionContext(id: String, to value: String) async throws {
        try await pluginDriver.switchSessionContext(id: id, to: value)
    }

    // MARK: - Batch Operations

    func sampleFieldPaths(table: String, limit: Int) async throws -> [PluginFieldPath] {
        try await pluginDriver.sampleFieldPaths(table: table, schema: pluginDriver.currentSchema, limit: limit)
    }

    func fetchAllColumns() async throws -> [String: [ColumnInfo]] {
        let pluginResult = try await pluginDriver.fetchAllColumns(schema: pluginDriver.currentSchema)
        var result: [String: [ColumnInfo]] = [:]
        for (table, cols) in pluginResult {
            result[table] = cols.map { col in
                ColumnInfo(name: col.name, dataType: col.dataType, isNullable: col.isNullable,
                           isPrimaryKey: col.isPrimaryKey, defaultValue: col.defaultValue,
                           extra: col.extra, charset: col.charset, collation: col.collation, comment: col.comment,
                           allowedValues: col.allowedValues)
            }
        }
        return result
    }

    var providesBulkForeignKeyFetch: Bool { pluginDriver.providesBulkForeignKeyFetch }

    func fetchAllForeignKeys() async throws -> [String: [ForeignKeyInfo]] {
        let pluginResult = try await pluginDriver.fetchAllForeignKeys(schema: pluginDriver.currentSchema)
        var result: [String: [ForeignKeyInfo]] = [:]
        for (table, fks) in pluginResult {
            result[table] = fks.map { fk in
                ForeignKeyInfo(name: fk.name, column: fk.column, referencedTable: fk.referencedTable,
                               referencedColumn: fk.referencedColumn, referencedSchema: fk.referencedSchema,
                               onDelete: fk.onDelete, onUpdate: fk.onUpdate)
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

    var supportsTransactions: Bool {
        pluginDriver.supportsTransactions
    }

    func beginTransaction() async throws {
        try await pluginDriver.beginTransaction()
    }

    func beginTransaction(mode: PluginTransactionAccessMode) async throws {
        try await pluginDriver.beginTransaction(mode: mode)
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

    var currentDatabase: String? {
        pluginDriver.currentDatabase
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

    func generateMoveColumnSQL(table: String, column: PluginColumnDefinition, afterColumn: String?) -> String? {
        pluginDriver.generateMoveColumnSQL(table: table, column: column, afterColumn: afterColumn)
    }

    func generateCreateTableSQL(definition: PluginCreateTableDefinition) -> String? {
        pluginDriver.generateCreateTableSQL(definition: definition)
    }

    // MARK: - Definition SQL (clipboard copy)

    func generateColumnDefinitionSQL(column: PluginColumnDefinition) -> String? {
        pluginDriver.generateColumnDefinitionSQL(column: column)
    }

    func generateIndexDefinitionSQL(index: PluginIndexDefinition, tableName: String?) -> String? {
        pluginDriver.generateIndexDefinitionSQL(index: index, tableName: tableName)
    }

    func generateForeignKeyDefinitionSQL(fk: PluginForeignKeyDefinition) -> String? {
        pluginDriver.generateForeignKeyDefinitionSQL(fk: fk)
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

    // MARK: - Maintenance Operations

    func supportedMaintenanceOperations() -> [String]? {
        pluginDriver.supportedMaintenanceOperations()
    }

    func maintenanceStatements(operation: String, table: String?, options: [String: String]) -> [String]? {
        pluginDriver.maintenanceStatements(operation: operation, table: table, schema: pluginDriver.currentSchema, options: options)
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
        let columnTypes = mapColumnTypes(rawTypeNames: pluginResult.columnTypeNames)
        var result = QueryResult(
            columns: pluginResult.columns,
            columnTypes: columnTypes,
            rows: pluginResult.rows,
            rowsAffected: pluginResult.rowsAffected,
            executionTime: pluginResult.executionTime,
            error: nil
        )
        result.isTruncated = pluginResult.isTruncated
        result.statusMessage = pluginResult.statusMessage
        result.columnMeta = pluginResult.columnMeta?.map {
            ResultColumnMeta(isPrimaryKey: $0.isPrimaryKey, isNullable: $0.isNullable, isAutoIncrement: $0.isIdentity)
        }
        return result
    }

    private func mapColumnTypes(rawTypeNames: [String]) -> [ColumnType] {
        state.withLock { state in
            rawTypeNames.map { rawTypeName in
                if let cached = state.columnTypeCache[rawTypeName] { return cached }
                let mapped = classifier.classify(rawTypeName: rawTypeName)
                state.columnTypeCache[rawTypeName] = mapped
                return mapped
            }
        }
    }
}

private extension PluginDriverAdapter {
    func mapFormSpec(_ spec: PluginCreateDatabaseFormSpec) -> CreateDatabaseFormSpec {
        CreateDatabaseFormSpec(
            fields: spec.fields.map(mapFormField),
            footnote: spec.footnote,
            textInputs: spec.textInputs.map(mapTextInput)
        )
    }

    func mapTextInput(_ input: PluginCreateDatabaseFormSpec.TextInput) -> CreateDatabaseFormSpec.TextInput {
        CreateDatabaseFormSpec.TextInput(
            id: input.id,
            label: input.label,
            placeholder: input.placeholder,
            isRequired: input.isRequired
        )
    }

    func mapFormField(_ field: PluginCreateDatabaseFormSpec.Field) -> CreateDatabaseFormSpec.Field {
        CreateDatabaseFormSpec.Field(
            id: field.id,
            label: field.label,
            kind: mapFieldKind(field.kind),
            visibleWhen: field.visibleWhen.map(mapVisibility),
            groupedBy: field.groupedBy
        )
    }

    func mapFieldKind(_ kind: PluginCreateDatabaseFormSpec.FieldKind) -> CreateDatabaseFormSpec.FieldKind {
        switch kind {
        case .picker(let options, let defaultValue):
            return .picker(options: options.map(mapOption), defaultValue: defaultValue)
        case .searchable(let options, let defaultValue):
            return .searchable(options: options.map(mapOption), defaultValue: defaultValue)
        }
    }

    func mapOption(_ option: PluginCreateDatabaseFormSpec.Option) -> CreateDatabaseFormSpec.Option {
        CreateDatabaseFormSpec.Option(
            value: option.value,
            label: option.label,
            subtitle: option.subtitle,
            group: option.group
        )
    }

    func mapVisibility(_ visibility: PluginCreateDatabaseFormSpec.Visibility) -> CreateDatabaseFormSpec.Visibility {
        CreateDatabaseFormSpec.Visibility(fieldId: visibility.fieldId, equals: visibility.equals)
    }
}
