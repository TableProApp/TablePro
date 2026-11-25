//
//  DatabaseDriver.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import Foundation
import OSLog
import TableProConnectionLibrary
import TableProPluginKit
import TableProRedisCore

/// Protocol defining database driver operations
protocol DatabaseDriver: AnyObject, Sendable {
    // MARK: - Properties

    /// The connection configuration
    var connection: DatabaseConnection { get }

    /// Current connection status
    var status: ConnectionStatus { get }

    var hasLostConnection: Bool { get }

    /// Server version string (e.g., "8.0.35" for MySQL)
    /// Optional - not all drivers may implement this
    var serverVersion: String? { get }

    /// The warning the server sent with the last login that succeeded. See
    /// `PluginDatabaseDriver.connectionWarning`.
    var connectionWarning: String? { get }

    /// The lexical facts the server decided for this session and the driver has read. See
    /// `PluginDatabaseDriver.sessionLexicalState`.
    var sessionLexicalState: PluginSessionLexicalState? { get }

    // MARK: - Connection Management

    /// Connect to the database
    func connect() async throws

    /// Connect while reporting the steps this driver can see from inside its own handshake.
    func connectReporting(stage report: @escaping ConnectionStageReporter) async throws

    /// Disconnect from the database
    func disconnect()

    /// Test the connection (connect and immediately disconnect)
    func testConnection() async throws -> Bool

    /// Check the connection is alive without mutating session state
    func ping() async throws

    // MARK: - Configuration

    /// Apply query execution timeout (seconds, 0 = no limit)
    func applyQueryTimeout(_ seconds: Int) async throws

    /// Mirrors `PluginDatabaseDriver.openSessionScope(for:)` and `closeSessionScope(_:)`.
    func openSessionScope(for purpose: PluginSessionPurpose) async throws -> PluginSessionScope?
    func closeSessionScope(_ scope: PluginSessionScope) async throws

    /// What the command that hands this connection's held resource back should be called, or nil
    /// when the driver holds nothing it can give up. A per-connection answer, not a per-engine one.
    var releasableResourceCommandTitle: String? { get }

    /// Hands that resource back now, keeping the session alive. A result that did not release is
    /// a refusal rather than a failure, and carries the reason: re-acquiring the resource would
    /// not restore what the session is currently holding.
    func releaseIdleResource() async throws -> PluginResourceRelease

    func importExportedDatabase(from folder: URL, into file: URL) async throws

    func resolveQueryCompletionProfile(
        databaseTypeId: String,
        base: QueryCompletionProfile
    ) async throws -> QueryCompletionProfile

    // MARK: - Query Execution

    /// Execute a SQL query and return results
    func execute(query: String) async throws -> QueryResult

    /// Execute a prepared statement with parameters (prevents SQL injection)
    /// - Parameters:
    ///   - query: SQL query with placeholders (? for MySQL/SQLite, $1/$2 for PostgreSQL)
    ///   - parameters: Array of parameter values to bind
    /// - Returns: Query result
    func executeParameterized(query: String, parameters: [Any?]) async throws -> QueryResult

    /// Execute user-supplied SQL with optional row cap and parameters.
    /// - Parameters:
    ///   - query: SQL passed through unchanged
    ///   - rowCap: Maximum rows to return; nil means no cap
    ///   - parameters: Optional parameter list; nil means no parameter binding
    /// - Returns: Query result with `isTruncated` set when the cap clipped rows
    func executeUserQuery(query: String, rowCap: Int?, parameters: [Any?]?) async throws -> QueryResult

    // The same calls for a statement an external caller had approved; `context` says what the approval covered.
    func executeUserQuery(
        query: String,
        rowCap: Int?,
        parameters: [Any?]?,
        context: PluginStatementContext
    ) async throws -> QueryResult

    func executeParameterized(
        query: String,
        parameters: [Any?],
        context: PluginStatementContext
    ) async throws -> QueryResult

    func execute(query: String, context: PluginStatementContext) async throws -> QueryResult

    // Whether this driver runs a statement marked read-only in the engine's read-only mode.
    var runsReadOnlyStatements: Bool { get }

    // Whether this driver runs a statement whose context `enforcesReadOnly` in the engine's read-only mode, or refuses
    // it, from every call that takes a context.
    var enforcesReadOnlyMode: Bool { get }

    /// Run a read that stops once `rowCap` rows are known to be exceeded, rather than fetching the
    /// whole result and discarding the tail. Returns nil when the driver cannot bound its own fetch.
    ///
    /// Call this only for a statement already classified as a read. Bounding means abandoning the
    /// rest of the fetch, which for some drivers cancels the statement on the server.
    func executeBoundedQuery(query: String, rowCap: Int) async throws -> QueryResult?

    // Nil also when the driver cannot honor `context` on a bounded read: the caller then runs `executeUserQuery` with the
    // same context and cap.
    func executeBoundedQuery(query: String, rowCap: Int, context: PluginStatementContext) async throws -> QueryResult?

    /// Runs a statement the app wrote to read, telling the driver it may only read. A driver that
    /// evaluates statements in a scripting engine with state refuses any write the script reaches,
    /// whatever an earlier statement redefined.
    func executeRead(query: String) async throws -> QueryResult

    /// Whether ``executeBatch(query:rowCap:parameters:)`` sends a text to the server whole and answers with every
    /// result set it produced.
    var supportsResultSetBatches: Bool { get }

    /// Send `query` as one batch and read it to the end. Returns nil when the driver cannot, and the caller runs the
    /// text statement by statement instead. A server error inside the batch is part of the answer, not a throw.
    func executeBatch(query: String, rowCap: Int?, parameters: [Any?]?) async throws -> QueryBatchResult?

    var supportsStatementBatches: Bool { get }

    // In order, stopping at the first failure. Nil when the driver sends these one at a time.
    func executeStatements(_ statements: [BatchedStatement]) async throws -> [BatchedStatementOutcome]?

    /// Whether ``copyFromStandardInput(statement:rows:context:)`` sends a `COPY ... FROM STDIN` its rows.
    var supportsCopyFromStandardInput: Bool { get }

    /// Runs `statement`, a `COPY ... FROM STDIN`, and sends it `rows` a piece at a time, holding the session until the
    /// copy ends. Throws when the driver cannot.
    func copyFromStandardInput(
        statement: String,
        rows: PluginCopyData,
        context: PluginStatementContext?
    ) async throws -> QueryResult

    func explainPlan(statement: String, variantId: String) async throws -> QueryResult

    // MARK: - Schema Operations

    // Nil names the connection's own schema; every read below takes the one its caller's scope holds.
    func fetchTables(schema: String?) async throws -> [TableInfo]

    /// Every schema's tables in one call, or nil when the engine has no such call and the caller
    /// has to ask each schema itself. `CatalogTableListing` is the caller that does.
    func fetchTablesInAllSchemas() async throws -> [TableInfo]?

    /// What `fetchTables(schema:)` lists for each named schema, in one call, each row with its own
    /// schema and ordered by schema then name. Nil means the caller asks each schema itself.
    func fetchTables(inSchemas schemas: [String]) async throws -> [TableInfo]?

    var listsTemporaryTables: Bool { get }

    // Only the session driver can answer: a pooled connection is another session.
    func fetchTemporaryTables() async throws -> [TableInfo]

    /// Fetch the direct partitions of one partitioned table, with each one's bound, position and
    /// row estimate. A partition is not a table on every engine, so this cannot answer `TableInfo`:
    /// a MySQL or Oracle partition name is unique only within its own table.
    func fetchPartitionDetails(table: String, schema: String?) async throws -> [PartitionInfo]

    func fetchColumns(table: String, schema: String?) async throws -> [ColumnInfo]

    // Every table's columns, keyed by name bytes: an engine can hold two names Swift's String equates.
    func fetchAllColumns(schema: String?) async throws -> [CatalogName: [ColumnInfo]]

    // One query that also reports every column `fetchColumns` does, so Compare can trust it.
    var providesBulkColumnFetch: Bool { get }

    // Only whether `fetchAllColumns` reads every table in one request, whatever its completeness.
    var fetchesAllColumnsInOneRequest: Bool { get }

    /// Dotted field paths a document store exposes for a collection, for query authoring.
    /// Default implementation returns nothing, which is correct for every SQL driver.
    func sampleFieldPaths(table: String, schema: String?, limit: Int) async throws -> [PluginFieldPath]

    func fetchIndexes(table: String, schema: String?) async throws -> [IndexInfo]
    func fetchForeignKeys(table: String, schema: String?) async throws -> [ForeignKeyInfo]
    func fetchCheckConstraints(table: String, schema: String?) async throws -> [CheckConstraintInfo]
    func fetchImmutableColumns(table: String, schema: String?) async throws -> Set<String>
    // From catalog statistics, for the pager; nil where the engine keeps none.
    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int?
    // A view answers with its own CREATE VIEW.
    func fetchTableDDL(table: String, schema: String?) async throws -> String
    // The CREATE INDEX and COMMENT statements `fetchTableDDL` does not carry inline.
    func fetchIndexDDL(table: String, schema: String?) async throws -> [String]
    func fetchCommentDDL(table: String, schema: String?) async throws -> [String]

    func fetchTriggers(table: String, schema: String?) async throws -> [TriggerInfo]

    // Nil when the driver cannot edit triggers.
    func createTriggerTemplate(table: String, schema: String?) -> String?
    func fetchTriggerDefinition(name: String, table: String, schema: String?) async throws -> String?
    func generateDropTriggerSQL(name: String, table: String, schema: String?) -> String?
    var triggerEditUsesReplace: Bool { get }
    var supportsTransactionalDDL: Bool { get }

    var unsupportedStructureColumnFields: Set<StructureColumnField> { get }
    var unsupportedIndexTypes: Set<String> { get }

    /// Why the connected server has no check constraints to list or edit, or nil when it has.
    var checkConstraintRefusal: String? { get }

    /// The save-level questions of a Structure save. See `PluginDatabaseDriver` for each. The
    /// defaults approve every save, find every save finished and keep nothing to forget.
    func reviewSchemaChange(
        table: String,
        schema: String?,
        operations: [PluginSchemaOperation]
    ) async throws -> PluginSchemaChangeReview

    func schemaChangeRefusalBeforeWriting(
        table: String,
        schema: String?,
        operations: [PluginSchemaOperation],
        review: PluginSchemaChangeReview
    ) async throws -> String?

    func schemaChangeShortfallAfterWriting(
        table: String,
        schema: String?,
        operations: [PluginSchemaOperation],
        review: PluginSchemaChangeReview
    ) async throws -> String?

    func tableDefinitionDidChange(table: String, schema: String?)

    func fetchAllForeignKeys(schema: String?) async throws -> [CatalogName: [ForeignKeyInfo]]

    /// Whether `fetchAllForeignKeys` is a single query. False means it degrades to one round trip
    /// per table, which is too expensive to run ahead of the user.
    var providesBulkForeignKeyFetch: Bool { get }

    func fetchForeignKeys(forTables tableNames: [String], schema: String?) async throws -> [CatalogName: [ForeignKeyInfo]]

    /// Fetch an exact row count for the table filtered by `filters`.
    /// Returns nil when the driver can't count a filtered set, so the caller falls back.
    func fetchFilteredRowCount(table: String, filters: [TableFilter], logicMode: FilterLogicMode) async throws -> Int?

    /// Fetch an exact row count for a user-initiated request. Drivers that cap their automatic
    /// counts to keep browsing responsive must not apply that cap here.
    func fetchExactRowCount(
        table: String,
        schema: String?,
        filters: [TableFilter],
        logicMode: FilterLogicMode
    ) async throws -> Int?

    /// The exact count of a browse narrowed by a search the plugin defines, such as Redis's key
    /// pattern and type, rather than by table filters. Nil when the driver has no such count.
    func fetchExactRowCount(table: String, schema: String?, browseFilters: [PluginQueryFilter]) async throws -> Int?

    // The PostgreSQL enum types a table's columns use, as (name, labels). Empty elsewhere.
    func fetchDependentTypes(forTable table: String, schema: String?) async throws -> [(name: String, labels: [String])]

    // The sequences a table's columns use, as (name, CREATE SEQUENCE). Empty elsewhere.
    func fetchDependentSequences(forTable table: String, schema: String?) async throws -> [(name: String, ddl: String)]

    func fetchViewDefinition(view: String, schema: String?) async throws -> String

    func fetchTableMetadata(tableName: String, schema: String?) async throws -> TableMetadata

    // The comment alone, which some engines answer without the row probe their metadata runs.
    func fetchObjectComment(tableName: String, schema: String?) async throws -> String?

    /// Fetch list of all databases on the server
    func fetchDatabases() async throws -> [String]

    /// Fetch list of schemas in the current database (PostgreSQL only)
    func fetchSchemas() async throws -> [String]

    /// Names of schemas whose objects live in a catalog outside the database.
    /// Default implementation returns an empty set; drivers that support them override.
    func fetchExternalSchemaNames() async throws -> Set<String>

    /// Fetch every stored procedure and function in the given schema (or the current schema if
    /// nil), in one round trip. Callers that want one kind filter the result rather than asking
    /// twice, so an engine is never queried twice for what a single catalog read answers.
    func fetchRoutines(schema: String?) async throws -> [RoutineInfo]

    /// Fetch the source of one routine. The routine must be one this driver listed, because its
    /// `identity` is the driver's own key for finding it again.
    func fetchRoutineDDL(_ routine: RoutineInfo) async throws -> String

    /// Fetch every named type the user created in the given schema, or the current schema if nil.
    func fetchUserDefinedTypes(schema: String?) async throws -> [UserDefinedTypeInfo]

    /// Every named type of each listed schema in one call, sorted by schema then name. Nil means the
    /// caller asks each schema itself.
    func fetchUserDefinedTypes(inSchemas schemas: [String]) async throws -> [UserDefinedTypeInfo]?

    /// Read one type again, definition and labels included. The type must be one this driver
    /// listed, because its `identity` is the driver's own key for finding it again.
    func fetchUserDefinedType(_ type: UserDefinedTypeInfo) async throws -> UserDefinedTypeInfo

    /// `cascade` also drops what depends on the type; nil when the driver has no such drop.
    func generateDropTypeSQL(type: UserDefinedTypeInfo, cascade: Bool) -> String?

    /// Mirrors `PluginDatabaseDriver.createUserDefinedTypeStatements(_:)`.
    func createUserDefinedTypeStatements(_ definition: PluginUserDefinedTypeDefinition) -> [String]?

    /// Mirrors `PluginDatabaseDriver.alterUserDefinedTypeStatements(type:change:)`.
    func alterUserDefinedTypeStatements(type: UserDefinedTypeInfo, change: PluginUserDefinedTypeChange) -> [String]?

    /// Mirrors `PluginDatabaseDriver.userDefinedTypeChangeRunsOutsideTransaction(_:)`.
    func userDefinedTypeChangeRunsOutsideTransaction(_ change: PluginUserDefinedTypeChange) -> Bool

    /// Fetch every trigger in the given schema, across all its tables.
    func fetchAllTriggers(schema: String?) async throws -> [TriggerInfo]

    /// Fetch the source of one trigger.
    func fetchTriggerDDL(_ trigger: TriggerInfo) async throws -> String

    // Mirrors `PluginDatabaseDriver.serverObjectKinds`: asked of the live driver, never of the type.
    var serverObjectKinds: [PluginServerObjectKind] { get }
    func fetchServerObjects(ofKind kindId: String, schema: String?) async throws -> [ServerObjectInfo]
    func fetchServerObject(_ object: ServerObjectInfo) async throws -> ServerObjectInfo

    /// Fetch metadata for a specific database (table count, size, etc.)
    func fetchDatabaseMetadata(_ database: String) async throws -> DatabaseMetadata

    /// Fetch metadata for all databases in a single batch (table count, size, etc.)
    /// Default implementation falls back to per-database calls.
    func fetchAllDatabaseMetadata() async throws -> [DatabaseMetadata]

    func createDatabaseFormSpec() async throws -> CreateDatabaseFormSpec?

    func createDatabase(_ request: CreateDatabaseRequest) async throws

    func createTableFormSpec(schema: String?) -> PluginCreateTableFormSpec?

    func createTableStatements(for request: PluginCreateTableRequest, schema: String?) throws -> [String]

    func dropDatabase(name: String) async throws

    func dropSchema(name: String) async throws

    func renameTable(name: String, schema: String?, to newName: String, objectType: String) async throws

    func renameDatabase(name: String, to newName: String) async throws

    func renameSchema(name: String, to newName: String) async throws

    func documentWriteStatement(_ write: PluginDocumentWrite) throws -> String?

    func executeDocumentWrite(_ write: PluginDocumentWrite) async throws

    func fetchDocument(table: String, schema: String?, locator: String) async throws -> String?

    func createSchemaStatements(_ definition: PluginSchemaDefinition) -> [String]?

    func renameSchemaStatements(name: String, to newName: String) -> [String]?

    func alterSchemaStatements(from current: PluginSchemaDetails, to target: PluginSchemaDefinition) -> [String]?

    func fetchSchemaDetails(name: String) async throws -> PluginSchemaDetails?

    func fetchSessionContexts() async throws -> [PluginSessionContext]?

    func switchSessionContext(id: String, to value: String) async throws

    // MARK: - Maintenance

    /// The maintenance operations this connection offers, each with the object kinds it may name, its
    /// scope and its options. Returns nil if maintenance is not supported.
    ///
    /// Descriptors rather than names, because the menu has to decide whether an operation applies to
    /// the object the user clicked: PostgreSQL skips a `VACUUM` on a view with a WARNING and the
    /// success command tag `VACUUM`, and refuses a `REINDEX` on one outright.
    func maintenanceOperations() -> [PluginMaintenanceOperation]?

    /// Generates SQL statements for a maintenance operation. The single source of the statement, so
    /// the confirmation sheet previews this rather than writing its own copy of the SQL.
    ///
    /// A nil `schema` means the caller genuinely has none to offer. Everything in the app does, and
    /// passes it: PostgreSQL resolves a bare name against `pg_temp` first, so a temp table of the
    /// same name is what got maintained.
    func maintenanceStatements(
        operation: String,
        table: String?,
        schema: String?,
        options: [String: String]
    ) -> [String]?

    // MARK: - Object Comments and Materialized Views

    /// Nil for an object kind the engine cannot comment on. Takes the object's own schema, never
    /// the connection's current one, because the object named may live anywhere in the tree.
    func objectCommentStatement(name: String, objectType: String, schema: String?, comment: String?) -> String?

    func refreshMaterializedViewStatement(name: String, schema: String?, concurrently: Bool) -> String?

    func concurrentRefreshAvailability(
        materializedView: String,
        schema: String?
    ) async throws -> PluginConcurrentRefreshAvailability?

    func fetchViewRowEditing(view: String, schema: String?) async throws -> PluginViewRowEditing?

    // MARK: - Table Options

    /// Nil where the engine has no table options.
    func fetchTableOptions(tableName: String, schema: String?) async throws -> TableOptions?

    func fetchTableOptionsCatalog() async throws -> TableOptionsCatalog?

    func fetchDefaultTableOptions(schema: String?) async throws -> TableOptions?

    /// Nil where the engine cannot make `change`. Takes the table's own schema, like `objectCommentStatement`.
    func tableOptionsStatement(tableName: String, schema: String?, change: PluginTableOptionsChange) -> String?

    // MARK: - Sequences

    func fetchSequenceDetails(sequence: String, schema: String?) async throws -> PluginSequenceDetails?
    func sequenceNextValueStatement(for sequence: PluginSequenceDetails, nextValue: PluginSequenceNextValue) -> String?
    func alterSequenceStatement(for sequence: PluginSequenceDetails, settings: PluginSequenceSettings) -> String?

    // MARK: - Query Cancellation

    /// Cancel the currently running query, if any.
    /// Default implementation is a no-op for drivers that don't support cancellation.
    func cancelQuery() throws

    // MARK: - Transaction Management

    /// Whether this driver supports transactions (e.g., Cloudflare D1, ClickHouse do not)
    var supportsTransactions: Bool { get }

    /// Begin a transaction
    func beginTransaction() async throws

    func beginTransaction(mode: PluginTransactionAccessMode) async throws

    /// Commit the current transaction
    func commitTransaction() async throws

    /// Rollback the current transaction
    func rollbackTransaction() async throws

    /// What the session is holding, so nothing the app owns opens, commits or rolls back a
    /// transaction over one the user already has open on the same session.
    func sessionTransactionState() async -> PluginSessionTransactionState

    /// Reads and consumes what the session printed on the server since the last read.
    func fetchServerOutput() async throws -> PluginServerOutput

    /// Access to the underlying plugin driver for query building dispatch
    var queryBuildingPluginDriver: (any PluginDatabaseDriver)? { get }

    // The driver row saves ask for statements. A plugin can write its rows without building its browse query.
    var rowWritingPluginDriver: (any PluginDatabaseDriver)? { get }

    var primaryKeyNamesOneRow: Bool { get }

    // The plugin this session drives, for the PluginKit surface the app calls as it is. Nil for a driver that wraps
    // none, so every caller states what happens without one.
    var plugin: (any PluginDatabaseDriver)? { get }

    // The query timeout the session was opened with, nil when the driver was given none.
    var sessionQueryTimeoutSeconds: Int? { get }

    // Texts sent that may have moved the session to another database; the host compares it with where it placed it.
    var databaseMoves: Int { get }

    func truncateTableStatements(table: String, schema: String?, cascade: Bool) -> [String]?
    func dropObjectStatement(name: String, objectType: String, schema: String?, cascade: Bool) -> String?

    func streamRows(query: String, safeModeIsReadOnly: Bool) -> AsyncThrowingStream<PluginStreamElement, Error>
    func streamExportRows(query: String, safeModeIsReadOnly: Bool) -> AsyncThrowingStream<PluginExportStreamElement, Error>

    /// Quote an identifier (table or column name) using the driver's quoting style
    func quoteIdentifier(_ name: String) -> String

    /// Escape a string value for safe use in SQL string literals
    func escapeStringLiteral(_ value: String) -> String

    func createViewTemplate() -> String?
    func editViewFallbackTemplate(viewName: String) -> String?
    func createSequenceTemplate() -> String?
    func castColumnToText(_ column: String) -> String

    func foreignKeyDisableStatements() -> [String]?
    func foreignKeyEnableStatements() -> [String]?
    func rowUpdateStatement(table: String, assignments: String, predicate: String) -> String?
    func rowDeleteStatement(table: String, predicate: String?) -> String?

    // Definition SQL for clipboard copy
    func generateColumnDefinitionSQL(column: PluginColumnDefinition) -> String?
    func generateIndexDefinitionSQL(index: PluginIndexDefinition, tableName: String?) -> String?
    func generateForeignKeyDefinitionSQL(fk: PluginForeignKeyDefinition) -> String?
}

// MARK: - Schema Switching

/// Protocol for drivers that support schema/search_path switching.
/// Eliminates repeated as? casting chains in DatabaseManager.
protocol SchemaSwitchable: DatabaseDriver {
    var currentSchema: String? { get }
    var escapedSchema: String? { get }
    func switchSchema(to schema: String) async throws
}

extension SchemaSwitchable {
    /// A driver already on the schema needs no statement, and sending one anyway is a round trip that
    /// can fail on its own. Every schema switch the app issues goes through here, so no two of them can
    /// disagree about when it is redundant: the pooled metadata driver kept sending an `ALTER SESSION`
    /// the session driver knew to skip, and on Oracle that spare statement was the one that hung (#2294).
    func switchSchemaIfNeeded(to schema: String) async throws {
        guard !CatalogName.same(currentSchema, schema) else { return }
        try await switchSchema(to: schema)
    }
}

/// Protocol for drivers that know which database they are on. An embedded engine names
/// its database from the file it opened, so the session cannot derive it from the
/// connection definition the way a networked engine can.
protocol DatabaseReporting: DatabaseDriver {
    var currentDatabase: String? { get }
}

/// Default implementation for common operations
extension DatabaseDriver {
    /// Default implementation returns nil
    /// Override in drivers that support version querying
    var serverVersion: String? { nil }

    var connectionWarning: String? { nil }

    var sessionLexicalState: PluginSessionLexicalState? { nil }

    func connectReporting(stage report: @escaping ConnectionStageReporter) async throws {
        try await connect()
    }

    func executeBoundedQuery(query: String, rowCap: Int) async throws -> QueryResult? { nil }

    // A driver without its own overload ignores every field, so a read-only mode, a statement policy or a catalog pin
    // it was asked for would silently not happen.
    func executeBoundedQuery(query: String, rowCap: Int, context: PluginStatementContext) async throws -> QueryResult? {
        guard !context.enforcesReadOnly, !context.readOnly, !context.readsCatalog,
              context.allowsDestructive, context.allowsServerCode
        else { return nil }
        return try await executeBoundedQuery(query: query, rowCap: rowCap)
    }

    var enforcesReadOnlyMode: Bool { false }

    // What a run carries when Safe Mode is Read-Only and this driver can hold the engine to it. Nil otherwise, so the run
    // keeps the calls it always made.
    func readOnlyRunContext(safeModeIsReadOnly: Bool) -> PluginStatementContext? {
        guard safeModeIsReadOnly, enforcesReadOnlyMode else { return nil }
        return PluginStatementContext(enforcesReadOnly: true)
    }

    func executeRead(query: String) async throws -> QueryResult {
        try await execute(query: query)
    }

    // A read the app wrote against the engine's own catalogs. PostgreSQL, KingbaseES and PGlite pin it to pg_catalog, so
    // a lookalike in the browsed schema never runs as the reader; Redshift and CockroachDB rely on qualified calls.
    func executeCatalogRead(query: String) async throws -> QueryResult {
        var context = PluginStatementContext()
        context.readOnly = true
        context.readsCatalog = true
        return try await execute(query: query, context: context)
    }

    func executeUserQuery(
        query: String,
        rowCap: Int?,
        parameters: [Any?]?,
        context: PluginStatementContext
    ) async throws -> QueryResult {
        try await executeUserQuery(query: query, rowCap: rowCap, parameters: parameters)
    }

    func executeParameterized(
        query: String,
        parameters: [Any?],
        context: PluginStatementContext
    ) async throws -> QueryResult {
        try await executeParameterized(query: query, parameters: parameters)
    }

    func execute(query: String, context: PluginStatementContext) async throws -> QueryResult {
        try await execute(query: query)
    }

    var runsReadOnlyStatements: Bool { false }

    var supportsResultSetBatches: Bool { false }

    func executeBatch(query: String, rowCap: Int?, parameters: [Any?]?) async throws -> QueryBatchResult? { nil }

    var supportsStatementBatches: Bool { false }

    func executeStatements(_ statements: [BatchedStatement]) async throws -> [BatchedStatementOutcome]? { nil }

    var supportsCopyFromStandardInput: Bool { false }

    func copyFromStandardInput(
        statement: String,
        rows: PluginCopyData,
        context: PluginStatementContext?
    ) async throws -> QueryResult {
        throw PluginDriverUnsupportedOperation.copyFromStandardInput
    }

    func explainPlan(statement: String, variantId: String) async throws -> QueryResult {
        throw PluginDriverUnsupportedOperation.explainPlan
    }

    func fetchIndexDDL(table: String, schema: String?) async throws -> [String] { [] }

    func fetchCommentDDL(table: String, schema: String?) async throws -> [String] { [] }

    func fetchObjectComment(tableName: String, schema: String?) async throws -> String? {
        try await fetchTableMetadata(tableName: tableName, schema: schema).comment
    }

    func resolveQueryCompletionProfile(
        databaseTypeId: String,
        base: QueryCompletionProfile
    ) async throws -> QueryCompletionProfile {
        base
    }

    var queryBuildingPluginDriver: (any PluginDatabaseDriver)? { nil }

    var databaseMoves: Int { 0 }

    var rowWritingPluginDriver: (any PluginDatabaseDriver)? { queryBuildingPluginDriver }

    var primaryKeyNamesOneRow: Bool { true }

    var plugin: (any PluginDatabaseDriver)? { nil }

    var sessionQueryTimeoutSeconds: Int? { nil }

    func truncateTableStatements(table: String, schema: String?, cascade: Bool) -> [String]? { nil }
    func dropObjectStatement(name: String, objectType: String, schema: String?, cascade: Bool) -> String? { nil }

    func streamRows(query: String, safeModeIsReadOnly: Bool) -> AsyncThrowingStream<PluginStreamElement, Error> {
        AsyncThrowingStream { $0.finish(throwing: DatabaseError.unsupportedOperation) }
    }

    func streamExportRows(
        query: String,
        safeModeIsReadOnly: Bool
    ) -> AsyncThrowingStream<PluginExportStreamElement, Error> {
        AsyncThrowingStream { $0.finish(throwing: DatabaseError.unsupportedOperation) }
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

    func beginTransaction(mode: PluginTransactionAccessMode) async throws {
        try await beginTransaction()
    }

    func sessionTransactionState() async -> PluginSessionTransactionState { .unknown }

    func fetchServerOutput() async throws -> PluginServerOutput { .none }

    func quoteIdentifier(_ name: String) -> String {
        SQLEscaping.quoteIdentifier(name)
    }

    func escapeStringLiteral(_ value: String) -> String {
        SQLEscaping.escapeStringLiteral(value)
    }

    func createViewTemplate() -> String? { nil }
    func editViewFallbackTemplate(viewName: String) -> String? { nil }
    func createSequenceTemplate() -> String? { nil }
    func castColumnToText(_ column: String) -> String { column }

    func foreignKeyDisableStatements() -> [String]? { nil }
    func foreignKeyEnableStatements() -> [String]? { nil }
    func rowUpdateStatement(table: String, assignments: String, predicate: String) -> String? { nil }
    func rowDeleteStatement(table: String, predicate: String?) -> String? { nil }

    func generateColumnDefinitionSQL(column: PluginColumnDefinition) -> String? { nil }
    func generateIndexDefinitionSQL(index: PluginIndexDefinition, tableName: String?) -> String? { nil }
    func generateForeignKeyDefinitionSQL(fk: PluginForeignKeyDefinition) -> String? { nil }

    func fetchImmutableColumns(table: String, schema: String?) async throws -> Set<String> { [] }

    func fetchCheckConstraints(table: String, schema: String?) async throws -> [CheckConstraintInfo] { [] }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? { nil }

    func fetchPartitionDetails(table: String, schema: String?) async throws -> [PartitionInfo] { [] }

    func fetchTriggers(table: String, schema: String?) async throws -> [TriggerInfo] { [] }

    func createTriggerTemplate(table: String, schema: String?) -> String? { nil }
    func fetchTriggerDefinition(name: String, table: String, schema: String?) async throws -> String? { nil }
    func generateDropTriggerSQL(name: String, table: String, schema: String?) -> String? { nil }
    var triggerEditUsesReplace: Bool { false }
    var supportsTransactionalDDL: Bool { false }

    var unsupportedStructureColumnFields: Set<StructureColumnField> { [] }
    var unsupportedIndexTypes: Set<String> { [] }
    var checkConstraintRefusal: String? { nil }

    func reviewSchemaChange(
        table: String,
        schema: String?,
        operations: [PluginSchemaOperation]
    ) async throws -> PluginSchemaChangeReview {
        PluginSchemaChangeReview()
    }

    func schemaChangeRefusalBeforeWriting(
        table: String,
        schema: String?,
        operations: [PluginSchemaOperation],
        review: PluginSchemaChangeReview
    ) async throws -> String? {
        nil
    }

    func schemaChangeShortfallAfterWriting(
        table: String,
        schema: String?,
        operations: [PluginSchemaOperation],
        review: PluginSchemaChangeReview
    ) async throws -> String? {
        nil
    }

    func tableDefinitionDidChange(table: String, schema: String?) {}

    func ping() async throws {
        _ = try await execute(query: "SELECT 1")
    }

    var releasableResourceCommandTitle: String? { nil }

    func releaseIdleResource() async throws -> PluginResourceRelease { .nothingToRelease }

    func importExportedDatabase(from folder: URL, into file: URL) async throws {
        throw PluginDriverUnsupportedOperation.importExportedDatabase
    }

    func testConnection() async throws -> Bool {
        try await connect()
        disconnect()
        return true
    }

    func dropDatabase(name: String) async throws {
        throw NSError(domain: "DatabaseDriver", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "Drop database is not supported by this driver"])
    }

    func dropSchema(name: String) async throws {
        throw NSError(domain: "DatabaseDriver", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "Drop schema is not supported by this driver"])
    }

    func renameTable(name: String, schema: String?, to newName: String, objectType: String) async throws {
        throw PluginDriverUnsupportedOperation.renameTable
    }

    func renameDatabase(name: String, to newName: String) async throws {
        throw PluginDriverUnsupportedOperation.renameDatabase
    }

    func renameSchema(name: String, to newName: String) async throws {
        throw PluginDriverUnsupportedOperation.renameSchema
    }

    func documentWriteStatement(_ write: PluginDocumentWrite) throws -> String? {
        throw PluginDriverUnsupportedOperation.writeDocument
    }

    func executeDocumentWrite(_ write: PluginDocumentWrite) async throws {
        throw PluginDriverUnsupportedOperation.writeDocument
    }

    func fetchDocument(table: String, schema: String?, locator: String) async throws -> String? {
        throw PluginDriverUnsupportedOperation.writeDocument
    }

    func createSchemaStatements(_ definition: PluginSchemaDefinition) -> [String]? { nil }

    func renameSchemaStatements(name: String, to newName: String) -> [String]? { nil }

    func alterSchemaStatements(
        from current: PluginSchemaDetails,
        to target: PluginSchemaDefinition
    ) -> [String]? { nil }

    func fetchSchemaDetails(name: String) async throws -> PluginSchemaDetails? { nil }

    func createDatabaseFormSpec() async throws -> CreateDatabaseFormSpec? { nil }

    func createTableFormSpec(schema: String?) -> PluginCreateTableFormSpec? { nil }

    func createTableStatements(for request: PluginCreateTableRequest, schema: String?) throws -> [String] {
        throw PluginCreateTableFormError(message: String(localized: "This database has no Create Table form"))
    }

    func fetchSessionContexts() async throws -> [PluginSessionContext]? { nil }

    func switchSessionContext(id: String, to value: String) async throws {}

    func createDatabase(_ request: CreateDatabaseRequest) async throws {
        throw NSError(
            domain: "DatabaseDriver",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Create database is not supported by this driver"]
        )
    }

    func fetchAllDatabaseMetadata() async throws -> [DatabaseMetadata] {
        let dbNames = try await fetchDatabases()
        var results: [DatabaseMetadata] = []
        for dbName in dbNames {
            try Task.checkCancellation()
            do {
                let metadata = try await fetchDatabaseMetadata(dbName)
                results.append(metadata)
            } catch {
                try Self.rethrowIfCancelled(error)
                results.append(DatabaseMetadata.minimal(name: dbName))
            }
        }
        return results
    }

    var providesBulkColumnFetch: Bool { false }

    var fetchesAllColumnsInOneRequest: Bool { false }

    var providesBulkForeignKeyFetch: Bool { false }

    func fetchAllForeignKeys(schema: String?) async throws -> [CatalogName: [ForeignKeyInfo]] {
        let allTables = try await fetchTables(schema: schema)
        return try await readEachTable(allTables.map(\.name), skippingFailures: true, reading: "foreign keys") { name in
            let keys = try await fetchForeignKeys(table: name, schema: schema)
            return keys.isEmpty ? nil : keys
        }
    }

    func fetchForeignKeys(forTables tableNames: [String], schema: String?) async throws -> [CatalogName: [ForeignKeyInfo]] {
        if providesBulkForeignKeyFetch, tableNames.count > 5 {
            let all = try await fetchAllForeignKeys(schema: schema)
            let nameSet = Set(tableNames.map { CatalogName($0) })
            return all.filter { nameSet.contains($0.key) }
        }
        // Without a bulk query the schema-wide read is a round trip per schema table; past five names an error still fails it.
        return try await readEachTable(tableNames, skippingFailures: tableNames.count <= 5, reading: "foreign keys") { name in
            let keys = try await fetchForeignKeys(table: name, schema: schema)
            return keys.isEmpty ? nil : keys
        }
    }

    func fetchIndexes(forTables tableNames: [String], schema: String?) async throws -> [CatalogName: [IndexInfo]] {
        try await readEachTable(tableNames, skippingFailures: true, reading: "indexes") { name in
            let indexes = try await fetchIndexes(table: name, schema: schema)
            return indexes.isEmpty ? nil : indexes
        }
    }

    private func readEachTable<Value>(
        _ tableNames: [String],
        skippingFailures: Bool,
        reading what: String,
        _ read: (String) async throws -> Value?
    ) async throws -> [CatalogName: Value] {
        var result: [CatalogName: Value] = [:]
        for name in tableNames {
            try Task.checkCancellation()
            do {
                if let value = try await read(name) { result[CatalogName(name)] = value }
            } catch {
                try Self.rethrowIfCancelled(error)
                guard skippingFailures else { throw error }
                Logger(subsystem: "com.TablePro", category: "DatabaseDriver")
                    .debug("Skipping \(what) for \(name): \(error.localizedDescription)")
            }
        }
        return result
    }

    private static func rethrowIfCancelled(_ error: any Error) throws {
        try Task.checkCancellation()
        if error is CancellationError { throw error }
    }

    func sampleFieldPaths(table: String, schema: String?, limit: Int) async throws -> [PluginFieldPath] {
        []
    }

    func fetchAllColumns(schema: String?) async throws -> [CatalogName: [ColumnInfo]] {
        let allTables = try await fetchTables(schema: schema)
        return try await readEachTable(allTables.map(\.name), skippingFailures: true, reading: "columns") { name in
            try await fetchColumns(table: name, schema: schema)
        }
    }

    func fetchDependentTypes(forTable table: String, schema: String?) async throws -> [(name: String, labels: [String])] {
        []
    }

    func fetchDependentSequences(forTable table: String, schema: String?) async throws -> [(name: String, ddl: String)] {
        []
    }

    func fetchFilteredRowCount(table: String, filters: [TableFilter], logicMode: FilterLogicMode) async throws -> Int? { nil }
    func fetchExactRowCount(
        table: String,
        schema: String?,
        filters: [TableFilter],
        logicMode: FilterLogicMode
    ) async throws -> Int? {
        try await fetchFilteredRowCount(table: table, filters: filters, logicMode: logicMode)
    }
    func fetchExactRowCount(table: String, schema: String?, browseFilters: [PluginQueryFilter]) async throws -> Int? { nil }

    func maintenanceOperations() -> [PluginMaintenanceOperation]? { nil }
    func maintenanceStatements(
        operation: String,
        table: String?,
        schema: String?,
        options: [String: String]
    ) -> [String]? { nil }

    func objectCommentStatement(name: String, objectType: String, schema: String?, comment: String?) -> String? {
        nil
    }

    func refreshMaterializedViewStatement(name: String, schema: String?, concurrently: Bool) -> String? { nil }

    func concurrentRefreshAvailability(
        materializedView: String,
        schema: String?
    ) async throws -> PluginConcurrentRefreshAvailability? {
        nil
    }

    func fetchViewRowEditing(view: String, schema: String?) async throws -> PluginViewRowEditing? { nil }

    func fetchTableOptions(tableName: String, schema: String?) async throws -> TableOptions? { nil }

    func fetchTableOptionsCatalog() async throws -> TableOptionsCatalog? { nil }

    func fetchDefaultTableOptions(schema: String?) async throws -> TableOptions? { nil }

    func tableOptionsStatement(tableName: String, schema: String?, change: PluginTableOptionsChange) -> String? {
        nil
    }

    func fetchSequenceDetails(sequence: String, schema: String?) async throws -> PluginSequenceDetails? { nil }

    func sequenceNextValueStatement(for sequence: PluginSequenceDetails, nextValue: PluginSequenceNextValue) -> String? {
        nil
    }

    func alterSequenceStatement(for sequence: PluginSequenceDetails, settings: PluginSequenceSettings) -> String? {
        nil
    }

    /// Default: no schema support (MySQL/SQLite don't use schemas in the same way)
    func fetchSchemas() async throws -> [String] { [] }

    func fetchExternalSchemaNames() async throws -> Set<String> { [] }

    func fetchTablesInAllSchemas() async throws -> [TableInfo]? { nil }

    func fetchTables(inSchemas schemas: [String]) async throws -> [TableInfo]? { nil }

    var listsTemporaryTables: Bool { false }

    func fetchTemporaryTables() async throws -> [TableInfo] { [] }

    func fetchRoutines(schema: String?) async throws -> [RoutineInfo] { [] }

    func fetchRoutineDDL(_ routine: RoutineInfo) async throws -> String {
        throw PluginObjectSourceError.unsupported(routine.name)
    }

    func fetchUserDefinedTypes(schema: String?) async throws -> [UserDefinedTypeInfo] { [] }

    func fetchUserDefinedTypes(inSchemas schemas: [String]) async throws -> [UserDefinedTypeInfo]? { nil }

    func fetchUserDefinedType(_ type: UserDefinedTypeInfo) async throws -> UserDefinedTypeInfo {
        guard let definition = type.definition, !definition.isEmpty else {
            throw PluginObjectSourceError.unsupported(type.name)
        }
        return type
    }

    func generateDropTypeSQL(type: UserDefinedTypeInfo, cascade: Bool) -> String? { nil }

    func createUserDefinedTypeStatements(_ definition: PluginUserDefinedTypeDefinition) -> [String]? { nil }

    func alterUserDefinedTypeStatements(type: UserDefinedTypeInfo, change: PluginUserDefinedTypeChange) -> [String]? {
        nil
    }

    func userDefinedTypeChangeRunsOutsideTransaction(_ change: PluginUserDefinedTypeChange) -> Bool { false }

    func fetchAllTriggers(schema: String?) async throws -> [TriggerInfo] { [] }

    func fetchTriggerDDL(_ trigger: TriggerInfo) async throws -> String {
        if let definition = trigger.definition, !definition.isEmpty { return definition }
        throw PluginObjectSourceError.unsupported(trigger.name)
    }

    var serverObjectKinds: [PluginServerObjectKind] { [] }

    func fetchServerObjects(ofKind kindId: String, schema: String?) async throws -> [ServerObjectInfo] { [] }

    func fetchServerObject(_ object: ServerObjectInfo) async throws -> ServerObjectInfo {
        guard let definition = object.definition, !definition.isEmpty else {
            throw PluginObjectSourceError.unsupported(object.name)
        }
        return object
    }

    var supportsTransactions: Bool { true }

    var hasLostConnection: Bool { false }

    func cancelQuery() throws {
    }

    /// Default timeout implementation — delegates to each plugin's PluginDatabaseDriver.
    /// The PluginDriverAdapter bridges this call to the plugin.
    func applyQueryTimeout(_ seconds: Int) async throws {
        // No-op: each plugin's PluginDatabaseDriver implements its own timeout command.
        // The PluginDriverAdapter bridges this call to the plugin.
    }

    func openSessionScope(for purpose: PluginSessionPurpose) async throws -> PluginSessionScope? { nil }

    func closeSessionScope(_ scope: PluginSessionScope) async throws {}
}

/// Which of the app's connections a driver is, so a plugin can name it to the server.
enum DriverPurpose: String, Sendable {
    case session
    case metadata
}

/// Factory for creating database drivers via plugin lookup
@MainActor
enum DatabaseDriverFactory {
    struct PreparedDriverConfiguration: Sendable {
        fileprivate let connectionId: UUID
        fileprivate let databaseTypeId: String
        fileprivate let purpose: DriverPurpose
        fileprivate let username: String
        fileprivate let sourceAdditionalFields: [String: String]
        fileprivate let additionalFields: [String: String]
    }

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "DatabaseDriverFactory")

    static func prepareConfiguration(
        for connection: DatabaseConnection,
        purpose: DriverPurpose = .session
    ) async throws -> PreparedDriverConfiguration {
        try await PluginManager.shared.prepareForConnecting(to: connection.type)
        guard let plugin = PluginManager.shared.driverPlugin(for: connection.type) else {
            throw PluginManager.shared.driverUnavailableError(for: connection.type)
        }
        // The tunnel opens from the linked SSH profile as it is now, not the row's stored copy of it.
        let tunneled = SSHProfileStorage.shared.refreshingLinkedProfile(connection)
        if let refusal = SSLModeNotSupportedError.refusal(for: tunneled, pluginType: type(of: plugin)) {
            throw refusal
        }
        if let refusal = DriverSettingNotSupportedError.refusal(for: tunneled, pluginType: type(of: plugin)) {
            throw refusal
        }

        var additionalFields = await readAdditionalFields(for: connection, plugin: plugin)
        if connection.usesIAMToken {
            additionalFields["enableCleartextPlugin"] = "true"
        }
        additionalFields["connectionId"] = connection.id.uuidString
        additionalFields["connectionPurpose"] = purpose.rawValue
        additionalFields = try LoadableExtensionGate.authorizedFields(additionalFields, for: connection)

        return PreparedDriverConfiguration(
            connectionId: connection.id,
            databaseTypeId: connection.type.pluginTypeId,
            purpose: purpose,
            username: ConnectionCredentialResolver.resolveUsername(for: connection),
            sourceAdditionalFields: connection.additionalFields,
            additionalFields: additionalFields
        )
    }

    /// Async variant that awaits background plugin loading instead of blocking the main thread.
    /// Preferred for all call sites that are already in an async context.
    static func createDriver(
        for connection: DatabaseConnection,
        passwordOverride: String? = nil,
        awaitPlugins: Bool,
        purpose: DriverPurpose = .session,
        deadline: ConnectionDeadline? = nil,
        timeoutEndpoint: ConnectionTimeoutEndpoint? = nil,
        effectiveQueryTimeoutSeconds: Int? = nil,
        preparedConfiguration: PreparedDriverConfiguration? = nil,
        initialSchema: String? = nil
    ) async throws -> DatabaseDriver {
        let prepared: PreparedDriverConfiguration
        if let preparedConfiguration {
            prepared = preparedConfiguration
        } else {
            prepared = try await prepareConfiguration(
                for: connection,
                purpose: purpose
            )
        }
        guard prepared.connectionId == connection.id,
              prepared.databaseTypeId == connection.type.pluginTypeId,
              prepared.purpose == purpose
        else {
            throw DatabaseError.connectionFailed(String(localized: "The prepared connection no longer matches this driver."))
        }
        let connectionDeadline = deadline ?? ConnectionDeadline(configuredSeconds: connection.connectTimeoutSeconds)
        let endpoint = timeoutEndpoint ?? .database(connection.timeoutEndpointName)
        let requiresHostDeadline = ConnectionTimeoutPolicy.requiresHostDeadline(for: connection)
        if requiresHostDeadline {
            try connectionDeadline.check(endpoint: endpoint)
        }
        return try await createDriverFromPlugin(
            for: connection,
            preparedConfiguration: prepared,
            passwordOverride: passwordOverride,
            deadline: connectionDeadline,
            timeoutEndpoint: endpoint,
            effectiveQueryTimeoutSeconds: effectiveQueryTimeoutSeconds,
            requiresHostDeadline: requiresHostDeadline,
            initialSchema: initialSchema
        )
    }

    private static func createDriverFromPlugin(
        for connection: DatabaseConnection,
        preparedConfiguration: PreparedDriverConfiguration,
        passwordOverride: String?,
        deadline: ConnectionDeadline,
        timeoutEndpoint: ConnectionTimeoutEndpoint,
        effectiveQueryTimeoutSeconds providedQueryTimeoutSeconds: Int?,
        requiresHostDeadline: Bool,
        initialSchema: String?
    ) async throws -> DatabaseDriver {
        guard let plugin = PluginManager.shared.driverPlugin(for: connection.type) else {
            throw PluginManager.shared.driverUnavailableError(for: connection.type)
        }
        var additionalFields = mergeEffectiveAdditionalFields(
            prepared: preparedConfiguration.additionalFields,
            source: preparedConfiguration.sourceAdditionalFields,
            effective: connection.additionalFields
        )
        let credentialFields = additionalFields
        let passwordMinter = ConnectionCredentialResolver.iamPasswordMinter(for: connection, fields: credentialFields)
        let signIn: ResolvedSignIn
        if requiresHostDeadline {
            signIn = try await resolvePasswordWithinDeadline(
                deadline: deadline,
                endpoint: timeoutEndpoint
            ) {
                try await ConnectionCredentialResolver.resolveSignIn(
                    for: connection,
                    fields: credentialFields,
                    override: passwordOverride,
                    deadline: deadline
                )
            }
        } else {
            signIn = try await ConnectionCredentialResolver.resolveSignIn(
                for: connection,
                fields: credentialFields,
                override: passwordOverride,
                deadline: nil
            )
        }
        let queryTimeoutSeconds = ConnectionTimeoutPolicy.effectiveQueryTimeoutSeconds(
            configuredSeconds: providedQueryTimeoutSeconds ?? connection.queryTimeoutSeconds,
            globalSeconds: AppSettingsManager.shared.general.queryTimeoutSeconds
        )
        let configurationSample = ContinuousClock.now
        if requiresHostDeadline {
            try deadline.check(endpoint: timeoutEndpoint, at: configurationSample)
        }
        for (key, value) in timeoutAdditionalFields(
            deadline: deadline,
            effectiveQueryTimeoutSeconds: queryTimeoutSeconds,
            databaseType: connection.type,
            usesRemainingBudget: requiresHostDeadline,
            at: configurationSample
        ) {
            additionalFields[key] = value
        }
        // A driver that can land on a schema while it signs in reads this, so the move costs no round trip of its own.
        if let initialSchema, !initialSchema.isEmpty {
            additionalFields["initialSchema"] = initialSchema
        }
        let config = DriverConnectionConfig(
            host: connection.host,
            port: connection.port,
            username: signIn.username ?? preparedConfiguration.username,
            password: keyDocumentSafePassword(signIn.password, plugin: plugin),
            database: connection.database,
            ssl: connection.transportSSLConfiguration,
            additionalFields: additionalFields,
            refreshPassword: passwordMinter?.refreshPassword
        )
        let pluginDriver = plugin.createDriver(config: config)
        return PluginDriverAdapter(
            connection: connection,
            pluginDriver: pluginDriver,
            deadline: deadline,
            timeoutEndpoint: timeoutEndpoint,
            effectiveQueryTimeoutSeconds: queryTimeoutSeconds,
            requiresHostDeadline: requiresHostDeadline,
            credentialLease: signIn.lease
        )
    }

    static func mergeEffectiveAdditionalFields(
        prepared: [String: String],
        source: [String: String],
        effective: [String: String]
    ) -> [String: String] {
        var merged = prepared
        for key in Set(source.keys).union(effective.keys) where source[key] != effective[key] {
            merged[key] = effective[key]
        }
        return merged
    }

    static func timeoutAdditionalFields(
        deadline: ConnectionDeadline,
        effectiveQueryTimeoutSeconds: Int,
        databaseType: DatabaseType? = nil,
        usesRemainingBudget: Bool = true,
        at now: ContinuousClock.Instant = .now
    ) -> [String: String] {
        let connectTimeoutSeconds = usesRemainingBudget
            ? max(1, deadline.remainingSeconds(at: now))
            : deadline.configuredSeconds
        let connectTimeoutMilliseconds = usesRemainingBudget
            ? max(1, deadline.remainingMilliseconds(at: now))
            : deadline.configuredSeconds * 1_000
        var fields = [
            "connectTimeoutSeconds": String(connectTimeoutSeconds),
            "connectTimeoutMilliseconds": String(connectTimeoutMilliseconds),
            "queryTimeoutSeconds": String(effectiveQueryTimeoutSeconds)
        ]
        if databaseType == .kafka {
            fields["kafkaConnectTimeout"] = fields["connectTimeoutSeconds"]
        }
        return fields
    }

    static func resolvePasswordWithinDeadline<Value: Sendable>(
        deadline: ConnectionDeadline,
        endpoint: ConnectionTimeoutEndpoint,
        resolver: @escaping @MainActor @Sendable () async throws -> Value
    ) async throws -> Value {
        try deadline.check(endpoint: endpoint)
        let gate = ConnectionSingleResumeGate<Value>()
        let operation = Task { @MainActor in
            do {
                gate.resume(with: .success(try await resolver()))
            } catch {
                gate.resume(with: .failure(error))
            }
        }
        let timeout = Task.detached {
            do {
                try await ContinuousClock().sleep(until: deadline.instant)
            } catch {
                return
            }
            if gate.resume(with: .failure(deadline.timeoutError(for: endpoint))) {
                operation.cancel()
            }
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler(
            operation: { try await gate.wait() },
            onCancel: {
                if gate.resume(with: .failure(CancellationError())) {
                    operation.cancel()
                }
            }
        )
    }

    /// The fields a connect would build for this connection, for a consumer that needs the same
    /// credential resolution without creating a driver. Nil when the plugin is not loaded.
    static func resolvedAdditionalFields(for connection: DatabaseConnection) -> [String: String]? {
        guard let plugin = PluginManager.shared.driverPlugin(for: connection.type) else { return nil }
        return buildAdditionalFields(for: connection, plugin: plugin)
    }

    // The factory sets these for every connect, so a value a saved, synced or imported row carries never reaches the
    // driver. The tunnel keys arrive on the effective connection, which `buildEffectiveConnection` builds.
    // A driver whose key field takes the password's place reads the key from the password, so a path there would sign in
    // with a key file on this Mac; a plugin built before that check reads it all the same.
    static func keyDocumentSafePassword(_ password: String, plugin: any DriverPlugin) -> String {
        let passwordTakesKey = type(of: plugin).additionalConnectionFields.contains { field in
            field.hidesPassword && ConnectionFieldCatalog.keyDocumentFieldIds.contains(field.id)
        }
        guard passwordTakesKey, !ConnectionFieldCatalog.isInlineKeyDocument(password) else { return password }
        return ""
    }

    private static let factoryOwnedFieldKeys: Set<String> = [
        "driverVariant",
        "enableCleartextPlugin",
        "connectionId",
        "connectionPurpose",
        "connectTimeoutMilliseconds",
    ]

    // The fields `buildAdditionalFields` gives plus the SSL key passphrase, with their Keychain reads run off the main
    // actor: one batch, and a second only for a profile that holds no value for a field it declares.
    static func readAdditionalFields(
        for connection: DatabaseConnection,
        plugin: any DriverPlugin,
        connectionStorage: ConnectionStorage = .shared,
        profileStorage: CredentialProfileStorage = .shared
    ) async -> [String: String] {
        let fieldIds = emptySecureFieldIds(in: baseAdditionalFields(for: connection, plugin: plugin), of: connection.type)
        let credentialProfile = fieldIds.isEmpty ? nil : linkedCredentialProfile(of: connection, in: profileStorage)
        let profileFieldIds = Set(fieldIds.filter { credentialProfile?.secureFieldIds.contains($0) == true })
        let fieldReads: [(fieldId: String, read: DeferredSecretRead)] = fieldIds.map { fieldId in
            if let credentialProfile, profileFieldIds.contains(fieldId) {
                return (fieldId, profileStorage.secureFieldRead(fieldId: fieldId, for: credentialProfile.id))
            }
            return (fieldId, connectionStorage.pluginSecureFieldRead(fieldId: fieldId, for: connection.id))
        }
        let passphraseRead = connectionStorage.sslClientKeyPassphraseRead(for: connection.id)
        let found = await DeferredSecretRead.run(fieldReads.map { $0.read } + [passphraseRead])

        var secrets: [String: String] = [:]
        var fallbackReads: [(fieldId: String, read: DeferredSecretRead)] = []
        for (fieldId, read) in fieldReads {
            if let value = found[read.key] {
                secrets[fieldId] = value
            } else if profileFieldIds.contains(fieldId) {
                fallbackReads.append((fieldId, connectionStorage.pluginSecureFieldRead(fieldId: fieldId, for: connection.id)))
            }
        }
        if !fallbackReads.isEmpty {
            let fallbackFound = await DeferredSecretRead.run(fallbackReads.map { $0.read })
            for (fieldId, read) in fallbackReads {
                secrets[fieldId] = fallbackFound[read.key]
            }
        }

        var fields = buildAdditionalFields(for: connection, plugin: plugin) { secrets[$0] }
        if let sslClientKeyPassphrase = found[passphraseRead.key], !sslClientKeyPassphrase.isEmpty {
            fields["sslClientKeyPassphrase"] = sslClientKeyPassphrase
        }
        return fields
    }

    static func buildAdditionalFields(
        for connection: DatabaseConnection,
        plugin: any DriverPlugin
    ) -> [String: String] {
        let credentialProfile = linkedCredentialProfile(of: connection, in: .shared)
        return buildAdditionalFields(for: connection, plugin: plugin) { fieldId in
            // A profile that declares the field holds its secret once, under the profile's id.
            if let credentialProfile, credentialProfile.secureFieldIds.contains(fieldId),
               let profileValue = CredentialProfileStorage.shared.loadSecureField(
                   fieldId: fieldId, for: credentialProfile.id
               ) {
                return profileValue
            }
            return ConnectionStorage.shared.loadPluginSecureField(fieldId: fieldId, for: connection.id)
        }
    }

    private static func linkedCredentialProfile(
        of connection: DatabaseConnection,
        in profileStorage: CredentialProfileStorage
    ) -> CredentialProfile? {
        connection.credentialMode.profileId.flatMap { profileStorage.profile(for: $0) }
    }

    // A key-document field holds the document or the path of a key file here. A stored plain value arrived from a file,
    // a link or another device, so only an inline document counts; the Keychain value the person entered fills it later.
    private static func baseAdditionalFields(
        for connection: DatabaseConnection,
        plugin: any DriverPlugin
    ) -> [String: String] {
        var fields = connection.additionalFields.filter { key, value in
            guard !factoryOwnedFieldKeys.contains(key) else { return false }
            return !ConnectionFieldCatalog.keyDocumentFieldIds.contains(key)
                || ConnectionFieldCatalog.isInlineKeyDocument(value)
        }
        if let variant = type(of: plugin).driverVariant(for: connection.type.rawValue) {
            fields["driverVariant"] = variant
        }
        return fields
    }

    // Every secure field the type declares, not only what the form renders: a Redshift row with `awsAuth` still
    // reads `awsSecretAccessKey` from here after its variant stopped offering the AWS section.
    private static func emptySecureFieldIds(in fields: [String: String], of databaseType: DatabaseType) -> [String] {
        PluginManager.shared.secureConnectionFieldIds(for: databaseType).filter { fields[$0]?.isEmpty ?? true }
    }

    private static func buildAdditionalFields(
        for connection: DatabaseConnection,
        plugin: any DriverPlugin,
        secret: (String) -> String?
    ) -> [String: String] {
        var fields = baseAdditionalFields(for: connection, plugin: plugin)
        for fieldId in emptySecureFieldIds(in: fields, of: connection.type) {
            if let value = secret(fieldId) {
                fields[fieldId] = value
            }
        }

        switch connection.type {
        case .mongodb:
            fields["mongoReadPreference"] = connection.mongoReadPreference ?? ""
            fields["mongoWriteConcern"] = connection.mongoWriteConcern ?? ""
        case .redis:
            fields[RedisDatabaseIndex.fieldName] = String(connection.redisDatabaseIndex)
        case .mssql:
            fields["mssqlSchema"] = connection.mssqlSchema ?? "dbo"
        case .oracle:
            fields["oracleServiceName"] = connection.oracleServiceName ?? ""
        default:
            break
        }

        return fields
    }
}
