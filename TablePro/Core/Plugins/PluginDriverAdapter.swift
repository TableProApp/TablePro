//
//  PluginDriverAdapter.swift
//  TablePro
//

import Foundation
import os
import TableProConnectionLibrary
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

    var hasLostConnection: Bool {
        pluginDriver.hasLostConnection
    }

    var serverVersion: String? { pluginDriver.serverVersion }
    var sessionLexicalState: PluginSessionLexicalState? { pluginDriver.sessionLexicalState }
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

    var releasableResourceCommandTitle: String? {
        pluginDriver.releasableResourceCommandTitle
    }

    func releaseIdleResource() async throws -> PluginResourceRelease {
        try await pluginDriver.releaseIdleResource()
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
        try StatementTextValidator.validate(query)
        let pluginResult = try await pluginDriver.execute(query: query)
        return mapQueryResult(pluginResult)
    }

    func executeParameterized(query: String, parameters: [Any?]) async throws -> QueryResult {
        try StatementTextValidator.validate(query)
        let cellParams: [PluginCellValue] = parameters.map(Self.cellValue(for:))
        let pluginResult = try await pluginDriver.executeParameterized(query: query, parameters: cellParams)
        return mapQueryResult(pluginResult)
    }

    func executeUserQuery(query: String, rowCap: Int?, parameters: [Any?]?) async throws -> QueryResult {
        try StatementTextValidator.validate(query)
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

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        if let error = StatementTextValidator.error(for: query) {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return pluginDriver.streamRows(query: query)
    }

    func executeBoundedQuery(query: String, rowCap: Int) async throws -> QueryResult? {
        try StatementTextValidator.validate(query)
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

    func fetchPartitionDetails(table: String, schema: String?) async throws -> [PartitionInfo] {
        let resolvedSchema = schema ?? pluginDriver.currentSchema
        let partitions = try await pluginDriver.fetchPartitionDetails(table: table, schema: resolvedSchema)
        return partitions.map { partition in
            let relationType = partition.relationType.flatMap(Self.mapPluginTableType)
            return PartitionInfo(
                name: partition.name,
                schema: relationType == nil ? partition.schema : (partition.schema ?? resolvedSchema),
                bound: partition.bound,
                ordinalPosition: partition.ordinalPosition,
                rowCount: partition.rowCount,
                relationType: relationType,
                isSubpartitioned: partition.isSubpartitioned,
                parentPartitionName: partition.parentPartitionName
            )
        }
    }

    /// One vocabulary for what a plugin calls an object, shared with the partition path so a
    /// foreign-table partition cannot arrive as a plain table and pick up Truncate on its way in.
    nonisolated internal static func mapPluginTableType(_ declaredType: String) -> TableInfo.TableType? {
        PluginTableKindDecoder.decode(declaredType).kind
    }

    private func mapPluginTable(_ table: PluginTableInfo, schemaFallback: String?) -> TableInfo {
        let decoded = PluginTableKindDecoder.decode(table.type)
        let tableType: TableInfo.TableType
        if let mapped = decoded.kind {
            tableType = mapped
        } else {
            Self.logger.warning("Unknown plugin table type \"\(table.type, privacy: .public)\" for \"\(table.name, privacy: .private(mask: .hash))\"; defaulting to .table")
            tableType = .table
        }
        return TableInfo(
            name: table.name,
            type: tableType,
            rowCount: table.rowCount,
            schema: table.schema ?? schemaFallback,
            comment: table.comment,
            partitionCount: table.partitionCount,
            isSystemVersioned: decoded.isSystemVersioned
        )
    }

    func fetchColumns(table: String) async throws -> [ColumnInfo] {
        let pluginColumns = try await pluginDriver.fetchColumns(table: table, schema: pluginDriver.currentSchema)
        return pluginColumns.map(ColumnInfo.init)
    }

    func fetchColumns(table: String, schema: String?) async throws -> [ColumnInfo] {
        let pluginColumns = try await pluginDriver.fetchColumns(table: table, schema: schema ?? pluginDriver.currentSchema)
        return pluginColumns.map(ColumnInfo.init)
    }

    func fetchIndexes(table: String) async throws -> [IndexInfo] {
        try await fetchIndexes(table: table, schema: nil)
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [IndexInfo] {
        let pluginIndexes = try await pluginDriver.fetchIndexes(
            table: table, schema: schema ?? pluginDriver.currentSchema
        )
        return pluginIndexes.map(IndexInfo.init)
    }

    func fetchForeignKeys(table: String) async throws -> [ForeignKeyInfo] {
        try await fetchForeignKeys(table: table, schema: nil)
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [ForeignKeyInfo] {
        let pluginFKs = try await pluginDriver.fetchForeignKeys(
            table: table, schema: schema ?? pluginDriver.currentSchema
        )
        return pluginFKs.map(ForeignKeyInfo.init)
    }

    func fetchCheckConstraints(table: String) async throws -> [CheckConstraintInfo] {
        try await fetchCheckConstraints(table: table, schema: nil)
    }

    func fetchCheckConstraints(table: String, schema: String?) async throws -> [CheckConstraintInfo] {
        let pluginConstraints = try await pluginDriver.fetchCheckConstraints(
            table: table, schema: schema ?? pluginDriver.currentSchema
        )
        return pluginConstraints.map(CheckConstraintInfo.init)
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

    var unsupportedStructureColumnFields: Set<StructureColumnField> { pluginDriver.unsupportedStructureColumnFields }

    var unsupportedIndexTypes: Set<String> { pluginDriver.unsupportedIndexTypes }

    var checkConstraintRefusal: String? { pluginDriver.checkConstraintRefusal }

    func fetchApproximateRowCount(table: String) async throws -> Int? {
        try await fetchApproximateRowCount(table: table, schema: nil)
    }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        try await pluginDriver.fetchApproximateRowCount(
            table: table, schema: schema ?? pluginDriver.currentSchema
        )
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
        try await fetchTableDDL(table: table, schema: nil)
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        try await pluginDriver.fetchTableDDL(table: table, schema: schema ?? pluginDriver.currentSchema)
    }

    func fetchIndexDDL(table: String) async throws -> [String] {
        try await fetchIndexDDL(table: table, schema: nil)
    }

    func fetchIndexDDL(table: String, schema: String?) async throws -> [String] {
        try await pluginDriver.fetchIndexDDL(table: table, schema: schema ?? pluginDriver.currentSchema)
    }

    func fetchCommentDDL(table: String) async throws -> [String] {
        try await fetchCommentDDL(table: table, schema: nil)
    }

    func fetchCommentDDL(table: String, schema: String?) async throws -> [String] {
        try await pluginDriver.fetchCommentDDL(table: table, schema: schema ?? pluginDriver.currentSchema)
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
        return TableMetadata(pluginMeta)
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
            Self.logger.warning("fetchRoutines failed: \(error.publicLogShape, privacy: .public)")
            throw error
        }
    }

    func fetchRoutineDDL(_ routine: RoutineInfo) async throws -> String {
        try await pluginDriver.fetchRoutineDDL(routine.pluginRoutine)
    }

    /// The resolved schema is stamped on any type that came back without one, the same backfill
    /// `fetchRoutines` does above. A driver that leaves it nil produces types whose qualified name
    /// is bare, which the sidebar then files under no schema at all.
    func fetchUserDefinedTypes(schema: String?) async throws -> [UserDefinedTypeInfo] {
        let resolvedSchema = schema ?? pluginDriver.currentSchema
        do {
            return try await pluginDriver.fetchUserDefinedTypes(schema: resolvedSchema)
                .map { UserDefinedTypeInfo($0.adoptingSchema(resolvedSchema)) }
                .sorted { $0.name < $1.name }
        } catch {
            Self.logger.warning("fetchUserDefinedTypes failed: \(error.publicLogShape, privacy: .public)")
            throw error
        }
    }

    func fetchUserDefinedType(_ type: UserDefinedTypeInfo) async throws -> UserDefinedTypeInfo {
        UserDefinedTypeInfo(try await pluginDriver.fetchUserDefinedType(type.pluginType))
    }

    func createTypeTemplate(schema: String?) -> String? {
        pluginDriver.createTypeTemplate(schema: schema ?? pluginDriver.currentSchema)
    }

    func generateAddEnumLabelSQL(type: UserDefinedTypeInfo, label: String, placement: EnumLabelPlacement?) -> String? {
        pluginDriver.generateAddEnumLabelSQL(type: type.pluginType, label: label, placement: placement?.pluginPlacement)
    }

    func generateRenameEnumLabelSQL(type: UserDefinedTypeInfo, from oldLabel: String, to newLabel: String) -> String? {
        pluginDriver.generateRenameEnumLabelSQL(type: type.pluginType, from: oldLabel, to: newLabel)
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> DatabaseMetadata {
        let pluginMeta = try await pluginDriver.fetchDatabaseMetadata(database)
        return Self.databaseMetadata(pluginMeta, systemDatabaseNames: systemDatabaseNames)
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

    func createSchemaStatements(_ definition: PluginSchemaDefinition) -> [String]? {
        pluginDriver.createSchemaStatements(definition)
    }

    func renameSchemaStatements(name: String, to newName: String) -> [String]? {
        pluginDriver.renameSchemaStatements(name: name, to: newName)
    }

    func alterSchemaStatements(
        from current: PluginSchemaDetails,
        to target: PluginSchemaDefinition
    ) -> [String]? {
        pluginDriver.alterSchemaStatements(from: current, to: target)
    }

    func fetchSchemaDetails(name: String) async throws -> PluginSchemaDetails? {
        try await pluginDriver.fetchSchemaDetails(name: name)
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
        return pluginResult.mapValues { $0.map(ColumnInfo.init) }
    }

    var providesBulkForeignKeyFetch: Bool { pluginDriver.providesBulkForeignKeyFetch }

    func fetchAllForeignKeys() async throws -> [String: [ForeignKeyInfo]] {
        let pluginResult = try await pluginDriver.fetchAllForeignKeys(schema: pluginDriver.currentSchema)
        return pluginResult.mapValues { $0.map(ForeignKeyInfo.init) }
    }

    func fetchAllDatabaseMetadata() async throws -> [DatabaseMetadata] {
        let pluginResult = try await pluginDriver.fetchAllDatabaseMetadata()
        let systemNames = systemDatabaseNames
        return pluginResult.map { Self.databaseMetadata($0, systemDatabaseNames: systemNames) }
    }

    /// The connection type's own list, added to whatever the driver reports. SQL Server and ClickHouse
    /// never set the flag, and MySQL leaves it off for a database with no readable tables, so trusting
    /// the flag alone listed `master` and `msdb` as user databases once the switcher's metadata landed,
    /// while the sidebar, classifying by the same list as here, kept them apart.
    private var systemDatabaseNames: Set<String> {
        Set(PluginMetadataRegistry.shared.snapshot(for: connection.type)?.schema.systemDatabaseNames ?? [])
    }

    nonisolated static func databaseMetadata(
        _ pluginMeta: PluginDatabaseMetadata,
        systemDatabaseNames: Set<String>
    ) -> DatabaseMetadata {
        let isSystem = pluginMeta.isSystemDatabase || systemDatabaseNames.contains(pluginMeta.name)
        return DatabaseMetadata(
            id: pluginMeta.name,
            name: pluginMeta.name,
            tableCount: pluginMeta.tableCount,
            sizeBytes: pluginMeta.sizeBytes,
            lastAccessed: nil,
            isSystemDatabase: isSystem,
            icon: isSystem ? "gearshape.fill" : "cylinder.fill"
        )
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

    func sessionTransactionState() async -> PluginSessionTransactionState {
        await pluginDriver.sessionTransactionState()
    }

    func fetchServerOutput() async throws -> PluginServerOutput {
        try await pluginDriver.fetchServerOutput()
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

    /// Routed to the session driver rather than through `withMetadataDriver`. A rebuild plan reads
    /// the catalog of the database this session is on, and a pooled driver is a second connection
    /// that an embedded engine answers from a different database entirely.
    func generateColumnReorderPlan(
        table: String,
        schema: String?,
        columns: [PluginColumnDefinition],
        desiredOrder: [String]
    ) async throws -> PluginColumnReorderPlan? {
        try await pluginDriver.generateColumnReorderPlan(
            table: table,
            schema: schema,
            columns: columns,
            desiredOrder: desiredOrder
        )
    }

    func generateTableRebuildPlan(
        table: String,
        schema: String?,
        respecification: PluginTableRespecification
    ) async throws -> PluginColumnReorderPlan? {
        try await pluginDriver.generateTableRebuildPlan(
            table: table,
            schema: schema,
            respecification: respecification
        )
    }

    func columnReorderSchemaFingerprint(table: String, schema: String?) async throws -> String? {
        try await pluginDriver.columnReorderSchemaFingerprint(table: table, schema: schema)
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

    /// Nil where the engine has no way to say it. The driver's own answer wins; the app builds the
    /// statement only for an engine whose DDL it can actually write, per `SQLDDLFallbackPolicy`.
    func truncateTableStatements(table: String, schema: String?, cascade: Bool) -> [String]? {
        if let stmts = pluginDriver.truncateTableStatements(table: table, schema: schema, cascade: cascade) {
            return stmts
        }
        guard allowsGeneratedDDL else { return nil }
        let name = qualifiedName(table, schema: schema)
        let cascadeSuffix = cascade ? " CASCADE" : ""
        return ["TRUNCATE TABLE \(name)\(cascadeSuffix)"]
    }

    func dropObjectStatement(name: String, objectType: String, schema: String?, cascade: Bool) -> String? {
        if let stmt = pluginDriver.dropObjectStatement(name: name, objectType: objectType, schema: schema, cascade: cascade) {
            return stmt
        }
        guard allowsGeneratedDDL else { return nil }
        let qualName = qualifiedName(name, schema: schema)
        let cascadeSuffix = cascade ? " CASCADE" : ""
        return "DROP \(objectType) \(qualName)\(cascadeSuffix)"
    }

    private var allowsGeneratedDDL: Bool {
        SQLDDLFallbackPolicy.allowsGeneratedDDL(for: connection.type)
    }

    /// Which of these objects this connection has a drop or truncate statement for.
    ///
    /// Resolved per object rather than per engine, because a plugin answers per object: Typesense
    /// has a statement for a collection and none for anything else, and Elasticsearch has none for
    /// an index name carrying a wildcard. Every menu that offers either operation asks this, so the
    /// answer and the statement it leads to come from one place.
    func tableOperationEligibility(
        for refs: some Collection<DatabaseTreeTableRef>,
        isReadOnly: Bool
    ) -> TableOperationEligibility.Context {
        guard !isReadOnly else { return .unavailable }
        var droppable: Set<DatabaseTreeTableRef> = []
        var truncatable: Set<DatabaseTreeTableRef> = []
        for ref in refs {
            if dropObjectStatement(
                name: ref.table.name,
                objectType: TableObjectKeyword.forDDL(ref.table.type),
                schema: ref.qualifyingSchema,
                cascade: false
            ) != nil {
                droppable.insert(ref)
            }
            if truncateTableStatements(
                table: ref.table.name, schema: ref.qualifyingSchema, cascade: false
            ) != nil {
                truncatable.insert(ref)
            }
        }
        return TableOperationEligibility.Context(
            droppable: droppable, truncatable: truncatable, isReadOnly: false
        )
    }

    func foreignKeyDisableStatements() -> [String]? {
        pluginDriver.foreignKeyDisableStatements()
    }

    func foreignKeyEnableStatements() -> [String]? {
        pluginDriver.foreignKeyEnableStatements()
    }

    // MARK: - Maintenance Operations

    func maintenanceOperations() -> [PluginMaintenanceOperation]? {
        pluginDriver.maintenanceOperations()
    }

    /// The session's own schema stands in only when the caller has none, so a command that does carry
    /// the object's schema qualifies with that one rather than with wherever the session points.
    func maintenanceStatements(
        operation: String,
        table: String?,
        schema: String?,
        options: [String: String]
    ) -> [String]? {
        pluginDriver.maintenanceStatements(
            operation: operation,
            table: table,
            schema: schema ?? pluginDriver.currentSchema,
            options: options
        )
    }

    // MARK: - Object Comments and Materialized Views

    func objectCommentStatement(name: String, objectType: String, schema: String?, comment: String?) -> String? {
        pluginDriver.objectCommentStatement(name: name, objectType: objectType, schema: schema, comment: comment)
    }

    func refreshMaterializedViewStatement(name: String, schema: String?, concurrently: Bool) -> String? {
        pluginDriver.refreshMaterializedViewStatement(name: name, schema: schema, concurrently: concurrently)
    }

    func concurrentRefreshAvailability(
        materializedView: String,
        schema: String?
    ) async throws -> PluginConcurrentRefreshAvailability? {
        try await pluginDriver.concurrentRefreshAvailability(materializedView: materializedView, schema: schema)
    }

    // MARK: - All Tables Metadata SQL

    func allTablesMetadataSQL(schema: String?) -> String? {
        pluginDriver.allTablesMetadataSQL(schema: schema)
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
        SchemaQualifiedName.render(
            name: name, schema: schema, databaseType: connection.type, quote: pluginDriver.quoteIdentifier
        )
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
        result.timing = pluginResult.timing
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
