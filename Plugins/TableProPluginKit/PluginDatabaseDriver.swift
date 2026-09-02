import Foundation

public enum PluginNumericLiteral {
    public static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        var scanner = value.makeIterator()
        var hasDigit = false
        var hasDot = false
        var hasE = false

        var first = true
        while let c = scanner.next() {
            if first {
                first = false
                if c == "-" || c == "+" { continue }
            }
            if c.isNumber {
                hasDigit = true
                continue
            }
            if c == "." && !hasDot && !hasE {
                hasDot = true
                continue
            }
            if (c == "e" || c == "E") && hasDigit && !hasE {
                hasE = true
                hasDigit = false
                if let next = scanner.next() {
                    if next == "+" || next == "-" || next.isNumber {
                        if next.isNumber { hasDigit = true }
                        continue
                    }
                }
                return false
            }
            return false
        }
        return hasDigit
    }
}

@frozen
public enum ParameterStyle: String, Sendable {
    case questionMark  // ?
    case dollar        // $1, $2
}

public struct PluginRowChange: Sendable {
    @frozen
    public enum ChangeType: Sendable {
        case insert
        case update
        case delete
    }

    public let rowIndex: Int
    public let type: ChangeType
    public let cellChanges: [(columnIndex: Int, columnName: String, oldValue: PluginCellValue, newValue: PluginCellValue)]
    public let originalRow: [PluginCellValue]?

    public init(
        rowIndex: Int,
        type: ChangeType,
        cellChanges: [(columnIndex: Int, columnName: String, oldValue: PluginCellValue, newValue: PluginCellValue)],
        originalRow: [PluginCellValue]?
    ) {
        self.rowIndex = rowIndex
        self.type = type
        self.cellChanges = cellChanges
        self.originalRow = originalRow
    }
}

public protocol PluginDatabaseDriver: AnyObject, Sendable {
    var capabilities: PluginCapabilities { get }

    func connect() async throws
    func connect(reportingStage report: @escaping ConnectionStageReporter) async throws
    func disconnect()
    func ping() async throws

    func execute(query: String) async throws -> PluginQueryResult

    func executeUserQuery(query: String, rowCap: Int?, parameters: [PluginCellValue]?) async throws -> PluginQueryResult

    /// Runs a read and stops once `rowCap` rows are known to be exceeded, instead of materializing
    /// the whole result and discarding the tail. Optional: return nil when the driver cannot bound
    /// the fetch at its source.
    ///
    /// Only the host may call this, and only for a statement it has already classified as a read:
    /// bounding a fetch means abandoning the rest of it, which for some drivers means cancelling the
    /// statement on the server.
    func executeBoundedQuery(query: String, rowCap: Int) async throws -> PluginQueryResult?

    func fetchTables(schema: String?) async throws -> [PluginTableInfo]
    func fetchPartitions(table: String, schema: String?) async throws -> [PluginTableInfo]
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo]
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo]
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo]
    func fetchTriggers(table: String, schema: String?) async throws -> [PluginTriggerInfo]
    func fetchCheckConstraints(table: String, schema: String?) async throws -> [PluginCheckConstraintInfo]
    func fetchAllTriggers(schema: String?) async throws -> [PluginTriggerInfo]
    var providesBulkTriggerFetch: Bool { get }
    func fetchTriggerDDL(_ trigger: PluginTriggerInfo) async throws -> String
    func fetchRoutines(schema: String?) async throws -> [PluginRoutineInfo]
    func fetchRoutineDDL(_ routine: PluginRoutineInfo) async throws -> String
    func fetchTableDDL(table: String, schema: String?) async throws -> String
    func fetchViewDefinition(view: String, schema: String?) async throws -> String
    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata
    func fetchDatabases() async throws -> [String]
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata

    var supportsSchemas: Bool { get }
    func fetchSchemas() async throws -> [String]
    func fetchExternalSchemaNames() async throws -> Set<String>
    func switchSchema(to schema: String) async throws
    var currentSchema: String? { get }

    var supportsTransactions: Bool { get }
    func beginTransaction() async throws
    func beginTransaction(mode: PluginTransactionAccessMode) async throws
    func commitTransaction() async throws
    func rollbackTransaction() async throws

    func cancelQuery() throws
    func applyQueryTimeout(_ seconds: Int) async throws
    var serverVersion: String? { get }
    var parameterStyle: ParameterStyle { get }
    func resolveQueryCompletionProfile(
        databaseTypeId: String,
        base: QueryCompletionProfile
    ) async throws -> QueryCompletionProfile

    var requiresBackslashEscapingInLiterals: Bool { get }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int?
    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]]
    var providesBulkColumnFetch: Bool { get }
    func sampleFieldPaths(table: String, schema: String?, limit: Int) async throws -> [PluginFieldPath]
    func fetchAllForeignKeys(schema: String?) async throws -> [String: [PluginForeignKeyInfo]]
    var providesBulkForeignKeyFetch: Bool { get }
    var tableDDLIncludesForeignKeys: Bool { get }
    func fetchAllIndexes(schema: String?) async throws -> [String: [PluginIndexInfo]]
    var providesBulkIndexFetch: Bool { get }
    func fetchAllTableMetadata(schema: String?) async throws -> [String: PluginTableMetadata]
    var providesBulkTableMetadataFetch: Bool { get }
    func fetchAllDatabaseMetadata() async throws -> [PluginDatabaseMetadata]
    func fetchDependentTypes(table: String, schema: String?) async throws -> [(name: String, labels: [String])]
    func fetchDependentSequences(table: String, schema: String?) async throws -> [(name: String, ddl: String)]
    func createDatabaseFormSpec() async throws -> PluginCreateDatabaseFormSpec?
    func createDatabase(_ request: PluginCreateDatabaseRequest) async throws
    func dropDatabase(name: String) async throws
    func dropSchema(name: String) async throws

    /// Renaming runs rather than generating a statement, because for several engines it is not a
    /// statement: MongoDB renames a collection through an admin command, SQL Server calls
    /// `sp_rename`. The driver also owns the quoting, which differs even between two SQLite
    /// builds here, and the rules for the new name: PostgreSQL and Oracle reject a qualified one,
    /// Snowflake accepts one and treats it as a move.
    func renameTable(name: String, schema: String?, to newName: String, objectType: String) async throws
    func renameDatabase(name: String, to newName: String) async throws
    func renameSchema(name: String, to newName: String) async throws
    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult

    // Session contexts (optional, switchable session dimensions such as a warehouse or role)
    func fetchSessionContexts() async throws -> [PluginSessionContext]?
    func switchSessionContext(id: String, to value: String) async throws

    // Query building (optional, for NoSQL plugins)
    func buildBrowseQuery(table: String, sortColumns: [(columnIndex: Int, ascending: Bool)], columns: [String], limit: Int, offset: Int) -> String?
    func buildFilteredQuery(table: String, filters: [(column: String, op: String, value: String)], logicMode: String, sortColumns: [(columnIndex: Int, ascending: Bool)], columns: [String], limit: Int, offset: Int) -> String?
    func buildBrowseQuery(table: String, schema: String?, sortColumns: [(columnIndex: Int, ascending: Bool)], columns: [String], limit: Int, offset: Int) -> String?
    func buildFilteredQuery(table: String, schema: String?, filters: [(column: String, op: String, value: String)], logicMode: String, sortColumns: [(columnIndex: Int, ascending: Bool)], columns: [String], limit: Int, offset: Int) -> String?
    func buildFilteredQuery(table: String, schema: String?, filters: [(column: String, op: String, value: String)], logicMode: String, sortColumns: [(columnIndex: Int, ascending: Bool)], columns: [String], limit: Int, offset: Int, columnKinds: [String: PluginColumnKind]) -> String?
    func buildFilteredQuery(table: String, schema: String?, queryFilters: [PluginQueryFilter], logicMode: String, sortColumns: [(columnIndex: Int, ascending: Bool)], columns: [String], limit: Int, offset: Int, columnKinds: [String: PluginColumnKind]) -> String?
    // Filtered row count (optional, for NoSQL plugins; SQL plugins use COUNT(*) WHERE)
    func fetchFilteredRowCount(table: String, filters: [(column: String, op: String, value: String)], logicMode: String) async throws -> Int?
    func fetchFilteredRowCount(table: String, queryFilters: [PluginQueryFilter], logicMode: String) async throws -> Int?
    // User-initiated exact row count (allowed to be slow; background count caps must not apply)
    func fetchExactRowCount(table: String, schema: String?, filters: [(column: String, op: String, value: String)], logicMode: String) async throws -> Int?
    func fetchExactRowCount(table: String, schema: String?, queryFilters: [PluginQueryFilter], logicMode: String) async throws -> Int?
    // Statement generation (optional, for NoSQL plugins)
    func generateStatements(table: String, columns: [String], primaryKeyColumns: [String], changes: [PluginRowChange], insertedRowData: [Int: [PluginCellValue]], deletedRowIndices: Set<Int>, insertedRowIndices: Set<Int>) -> [(statement: String, parameters: [PluginCellValue])]?
    func generateStatements(table: String, schema: String?, columns: [String], primaryKeyColumns: [String], changes: [PluginRowChange], insertedRowData: [Int: [PluginCellValue]], deletedRowIndices: Set<Int>, insertedRowIndices: Set<Int>) -> [(statement: String, parameters: [PluginCellValue])]?

    /// Writes a row back exactly as it was, key included, to undo a delete.
    ///
    /// `generateStatements` writes an insert for a row the user just added, so it is free to let
    /// the server pick the key and MongoDB's drops `_id` on purpose. Replaying that to undo a
    /// delete produces a different document rather than the one that went missing. Return nil to
    /// say this driver cannot restore a row's identity, and the host will refuse rather than write
    /// something close.
    func generateIdentityPreservingInsert(table: String, schema: String?, columns: [String], primaryKeyColumns: [String], rows: [[PluginCellValue]]) -> [(statement: String, parameters: [PluginCellValue])]?

    // Database switching (SQL Server USE, ClickHouse database switch, etc.)
    func switchDatabase(to database: String) async throws

    /// The database the connection is currently on, when the driver rather than the
    /// connection definition is the authority on that. An embedded engine names its
    /// database from the file it opened, so nothing outside the driver can derive it.
    /// Drivers whose database comes from the connection definition return nil.
    var currentDatabase: String? { get }

    // DDL schema generation (optional, plugins return nil to use default fallback)
    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String?
    func generateModifyColumnSQL(table: String, oldColumn: PluginColumnDefinition, newColumn: PluginColumnDefinition) -> String?
    func generateDropColumnSQL(table: String, columnName: String) -> String?
    func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String?
    func generateDropIndexSQL(table: String, indexName: String) -> String?
    func generateAddForeignKeySQL(table: String, fk: PluginForeignKeyDefinition) -> String?
    func generateDropForeignKeySQL(table: String, constraintName: String) -> String?
    func generateAddCheckConstraintSQL(table: String, constraint: PluginCheckConstraintDefinition) -> String?
    func generateDropCheckConstraintSQL(table: String, constraintName: String) -> String?
    func generateRenameCheckConstraintSQL(table: String, from oldName: String, to newName: String) -> String?
    func generateModifyPrimaryKeySQL(table: String, oldColumns: [String], newColumns: [String], constraintName: String?) -> [String]?
    func generateMoveColumnSQL(table: String, column: PluginColumnDefinition, afterColumn: String?) -> String?

    /// The statements that put `table`'s columns into `desiredOrder`, or nil where the engine
    /// cannot reorder them.
    ///
    /// Supersedes `generateMoveColumnSQL`, which can only say "one `ALTER`, one column" and so
    /// cannot express Oracle's invisible/visible cycle or the create-copy-swap a rebuild engine
    /// needs. The old requirement stays published and defaulted: removing one breaks every plugin
    /// whose witness table hard-references its default.
    ///
    /// `columns` is the table's current definitions in current order, so a driver that has to
    /// restate a column keeps the charset and collation the app already resolved. Anything else a
    /// rebuild needs, the driver queries for itself.
    func generateColumnReorderPlan(
        table: String,
        schema: String?,
        columns: [PluginColumnDefinition],
        desiredOrder: [String]
    ) async throws -> PluginColumnReorderPlan?

    /// A fingerprint of everything a reorder plan reproduces, cheap enough to take twice.
    ///
    /// A rebuild plan is built before its review sheet opens and run after it closes, and it ends
    /// in a `DROP`. Anything another connection added in between is inside the table the plan is
    /// about to drop and outside the plan that is about to replace it. Comparing this before and
    /// after is what turns that into a refusal instead of silent loss. Nil where the driver cannot
    /// answer, which stands the check down for an engine TablePro never runs a rebuild on anyway.
    func columnReorderSchemaFingerprint(table: String, schema: String?) async throws -> String?

    func generateCreateTableSQL(definition: PluginCreateTableDefinition) -> String?

    // Definition SQL for clipboard copy (optional — return nil if not supported)
    func generateColumnDefinitionSQL(column: PluginColumnDefinition) -> String?
    func generateIndexDefinitionSQL(index: PluginIndexDefinition, tableName: String?) -> String?
    func generateForeignKeyDefinitionSQL(fk: PluginForeignKeyDefinition) -> String?

    // Table operations (optional — return nil to use app-level fallback)
    func truncateTableStatements(table: String, schema: String?, cascade: Bool) -> [String]?
    func dropObjectStatement(name: String, objectType: String, schema: String?, cascade: Bool) -> String?
    func foreignKeyDisableStatements() -> [String]?
    func foreignKeyEnableStatements() -> [String]?

    /// Creates a schema, for a copy that has just created the database it goes in.
    ///
    /// A new database carries only whatever schema its engine gives it, so duplicating one that
    /// groups its objects into several means creating the rest before any of their tables. Return
    /// nil where the engine has no schemas, or where a schema is not something a statement can
    /// make: on Oracle it is a user, and on SQL Server it needs its own batch. Callers leave those
    /// namespaces out and say so rather than emitting DDL the server will reject.
    func createSchemaStatement(name: String) -> String?

    // Maintenance operations (optional — return nil if not supported)
    func supportedMaintenanceOperations() -> [String]?
    func maintenanceStatements(operation: String, table: String?, schema: String?, options: [String: String]) -> [String]?

    // EXPLAIN query building (optional)
    func buildExplainQuery(_ sql: String) -> String?

    func injectRowLimit(_ sql: String, limit: Int) -> String?

    func quoteIdentifier(_ name: String) -> String

    func escapeStringLiteral(_ value: String) -> String

    func createViewTemplate() -> String?
    func editViewFallbackTemplate(viewName: String) -> String?
    func castColumnToText(_ column: String) -> String

    // Trigger editing (optional — return nil when unsupported)
    func createTriggerTemplate(table: String, schema: String?) -> String?
    func fetchTriggerDefinition(name: String, table: String, schema: String?) async throws -> String?
    func generateDropTriggerSQL(name: String, table: String, schema: String?) -> String?
    func generateDropRoutineSQL(name: String, signature: String?, schema: String?, isFunction: Bool) -> String?
    var triggerEditUsesReplace: Bool { get }
    var supportsTransactionalDDL: Bool { get }

    // All-tables metadata SQL (optional — returns nil for non-SQL databases)
    func allTablesMetadataSQL(schema: String?) -> String?

    // Default export query (optional — returns nil to use app-level fallback)
    func defaultExportQuery(table: String) -> String?
    func defaultExportQuery(table: String, schema: String?) -> String?

    // Streaming row fetch for export
    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error>
}

public extension PluginDatabaseDriver {
    var capabilities: PluginCapabilities { [] }

    /// A driver that cannot see inside its own connect keeps the plain path. The app still
    /// reports the stages either side of this call, so the window is never blank.
    func connect(reportingStage report: @escaping ConnectionStageReporter) async throws {
        try await connect()
    }

    func fetchTriggers(table: String, schema: String?) async throws -> [PluginTriggerInfo] { [] }

    func fetchCheckConstraints(table: String, schema: String?) async throws -> [PluginCheckConstraintInfo] { [] }

    func fetchAllTriggers(schema: String?) async throws -> [PluginTriggerInfo] { [] }

    /// Answers whether `fetchAllTriggers` lists a whole schema's triggers. The default above
    /// returns nothing rather than looping, so a caller that wants triggers has to know whether
    /// this driver answers at all before it decides to ask per table. False is the safe answer: it
    /// costs a round trip per table and reports every trigger, where a wrong true reports none.
    var providesBulkTriggerFetch: Bool { false }

    func fetchTriggerDDL(_ trigger: PluginTriggerInfo) async throws -> String {
        if let definition = trigger.definition, !definition.isEmpty { return definition }
        guard let table = trigger.table else {
            throw PluginObjectSourceError.unsupported(trigger.name)
        }
        guard let existing = try await fetchTriggerDefinition(
            name: trigger.name,
            table: table,
            schema: trigger.schema
        ) else {
            throw PluginObjectSourceError.unsupported(trigger.name)
        }
        return existing
    }

    /// A driver written against `PluginProcedureFunctionSupport` keeps working untouched: the
    /// runtime fills this requirement from here, and here adopts that conformance. The app only
    /// ever calls this one, so nothing above PluginKit has to know the older protocol exists.
    func fetchRoutines(schema: String?) async throws -> [PluginRoutineInfo] {
        guard let legacy = self as? PluginProcedureFunctionSupport else { return [] }
        let procedures = try await legacy.fetchProcedures(schema: schema)
        let functions = try await legacy.fetchFunctions(schema: schema)
        return procedures.map { $0.adopting(kind: .procedure, schema: schema) }
            + functions.map { $0.adopting(kind: .function, schema: schema) }
    }

    func fetchRoutineDDL(_ routine: PluginRoutineInfo) async throws -> String {
        guard let legacy = self as? PluginProcedureFunctionSupport else {
            throw PluginObjectSourceError.unsupported(routine.name)
        }
        switch routine.kind {
        case .procedure:
            return try await legacy.fetchProcedureDDL(name: routine.name, schema: routine.schema)
        case .function:
            return try await legacy.fetchFunctionDDL(name: routine.name, schema: routine.schema)
        }
    }

    /// Engines whose partitions are metadata on one table object, rather than
    /// separate relations, have nothing to nest and keep the empty default.
    func fetchPartitions(table: String, schema: String?) async throws -> [PluginTableInfo] { [] }

    func createTriggerTemplate(table: String, schema: String?) -> String? { nil }
    func fetchTriggerDefinition(name: String, table: String, schema: String?) async throws -> String? { nil }
    func generateDropTriggerSQL(name: String, table: String, schema: String?) -> String? { nil }

    /// How this engine drops a routine, given that only some of them accept an argument list.
    ///
    /// PostgreSQL requires one to tell `f(integer)` from `f(text)`, and MySQL rejects one outright,
    /// so a caller cannot spell this itself. Returning nil means the caller's own qualified
    /// `DROP FUNCTION schema.name` is right for this engine.
    func generateDropRoutineSQL(
        name: String,
        signature: String?,
        schema: String?,
        isFunction: Bool
    ) -> String? { nil }
    var triggerEditUsesReplace: Bool { false }
    var supportsTransactionalDDL: Bool { false }

    var supportsSchemas: Bool { false }

    func fetchSchemas() async throws -> [String] { [] }

    /// Schemas whose objects live in a catalog outside the database itself, such
    /// as Redshift external schemas backed by Glue, Hive, or a federated source.
    /// Engines without that concept keep the empty default.
    func fetchExternalSchemaNames() async throws -> Set<String> { [] }

    func switchSchema(to schema: String) async throws {}

    var currentSchema: String? { nil }

    var supportsTransactions: Bool { true }

    func beginTransaction() async throws {
        _ = try await execute(query: "BEGIN")
    }

    func beginTransaction(mode: PluginTransactionAccessMode) async throws {
        try await beginTransaction()
    }

    func commitTransaction() async throws {
        _ = try await execute(query: "COMMIT")
    }

    func rollbackTransaction() async throws {
        _ = try await execute(query: "ROLLBACK")
    }

    func cancelQuery() throws {}

    func applyQueryTimeout(_ seconds: Int) async throws {}

    func ping() async throws {
        _ = try await execute(query: "SELECT 1")
    }

    var serverVersion: String? { nil }

    var parameterStyle: ParameterStyle { .questionMark }

    func resolveQueryCompletionProfile(
        databaseTypeId: String,
        base: QueryCompletionProfile
    ) async throws -> QueryCompletionProfile {
        base
    }

    var requiresBackslashEscapingInLiterals: Bool { false }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? { nil }

    /// Answers whether `fetchAllColumns` is a single query rather than the N+1 default below, and
    /// whether it reports every column `fetchColumns` reports. Both halves matter: a bulk query
    /// that omits generated columns or their expressions is not a substitute for the per-table
    /// read, and a caller that compares two schemas would report the missing detail as no
    /// difference at all.
    var providesBulkColumnFetch: Bool { false }

    /// Default: fetches columns per-table sequentially (N+1 round-trips).
    /// SQL drivers should override with a single bulk query (e.g. INFORMATION_SCHEMA.COLUMNS).
    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        let tables = try await fetchTables(schema: schema)
        var result: [String: [PluginColumnInfo]] = [:]
        for table in tables {
            result[table.name] = try await fetchColumns(table: table.name, schema: schema)
        }
        return result
    }

    /// Default: no nested field paths. Document stores override this to sample documents and
    /// report the dotted paths their nested structure exposes, which a flat column list cannot.
    func sampleFieldPaths(table: String, schema: String?, limit: Int) async throws -> [PluginFieldPath] {
        []
    }

    /// Answers whether `fetchTableDDL` already carries the table's FOREIGN KEY constraints, which
    /// every driver returning the server's own CREATE statement does. A SQL export defers foreign
    /// keys to `ALTER TABLE ... ADD CONSTRAINT` after the data, so it must skip that for a driver
    /// answering `true` or the dump declares each constraint twice, and SQLite has no such
    /// statement to declare it with at all.
    ///
    /// Defaults to `false`, which is the behaviour every driver shipped before this existed: the
    /// export adds the foreign keys itself. A driver whose DDL carries them overrides it.
    var tableDDLIncludesForeignKeys: Bool { false }

    /// Answers whether `fetchAllForeignKeys` is a single query rather than the N+1 default below.
    /// The app reads this before fetching a whole schema's foreign keys up front, so a driver that
    /// has not overridden the default is never asked to make one round trip per table. It belongs
    /// on the driver rather than on the database type, because the PostgreSQL plugin registers
    /// CockroachDB and Redshift as variants of its own type and neither has the bulk query.
    var providesBulkForeignKeyFetch: Bool { false }

    /// Default: fetches foreign keys per-table sequentially (N+1 round-trips).
    /// SQL drivers should override with a single bulk query (e.g. INFORMATION_SCHEMA.KEY_COLUMN_USAGE).
    func fetchAllForeignKeys(schema: String?) async throws -> [String: [PluginForeignKeyInfo]] {
        let tables = try await fetchTables(schema: schema)
        var result: [String: [PluginForeignKeyInfo]] = [:]
        for table in tables {
            let fks = try await fetchForeignKeys(table: table.name, schema: schema)
            if !fks.isEmpty { result[table.name] = fks }
        }
        return result
    }

    /// Answers whether `fetchAllIndexes` is a single query rather than the N+1 default below.
    var providesBulkIndexFetch: Bool { false }

    /// Default: fetches indexes per-table sequentially (N+1 round-trips).
    /// SQL drivers should override with a single bulk query (e.g. INFORMATION_SCHEMA.STATISTICS).
    func fetchAllIndexes(schema: String?) async throws -> [String: [PluginIndexInfo]] {
        let tables = try await fetchTables(schema: schema)
        var result: [String: [PluginIndexInfo]] = [:]
        for table in tables {
            let indexes = try await fetchIndexes(table: table.name, schema: schema)
            if !indexes.isEmpty { result[table.name] = indexes }
        }
        return result
    }

    /// Answers whether `fetchAllTableMetadata` is a single query rather than the N+1 default below.
    var providesBulkTableMetadataFetch: Bool { false }

    /// Default: fetches metadata per-table sequentially (N+1 round-trips).
    /// SQL drivers should override with a single bulk query (e.g. SHOW TABLE STATUS with no filter).
    ///
    /// A table whose metadata cannot be read is left out rather than throwing. The caller wants
    /// the descriptive fields, and one unreadable table is not a reason to lose the other 199.
    func fetchAllTableMetadata(schema: String?) async throws -> [String: PluginTableMetadata] {
        let tables = try await fetchTables(schema: schema)
        var result: [String: PluginTableMetadata] = [:]
        for table in tables {
            guard let metadata = try? await fetchTableMetadata(table: table.name, schema: schema) else { continue }
            result[table.name] = metadata
        }
        return result
    }

    func fetchAllDatabaseMetadata() async throws -> [PluginDatabaseMetadata] {
        let dbs = try await fetchDatabases()
        var result: [PluginDatabaseMetadata] = []
        for db in dbs {
            do {
                result.append(try await fetchDatabaseMetadata(db))
            } catch {
                result.append(PluginDatabaseMetadata(name: db))
            }
        }
        return result
    }

    func fetchDependentTypes(table: String, schema: String?) async throws -> [(name: String, labels: [String])] { [] }
    func fetchDependentSequences(table: String, schema: String?) async throws -> [(name: String, ddl: String)] { [] }

    func createDatabaseFormSpec() async throws -> PluginCreateDatabaseFormSpec? { nil }

    func createDatabase(_ request: PluginCreateDatabaseRequest) async throws {
        throw NSError(
            domain: "PluginDatabaseDriver",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Create database is not supported by this driver"]
        )
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

    func dropDatabase(name: String) async throws {
        throw NSError(domain: "PluginDatabaseDriver", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "Drop database is not supported by this driver"])
    }

    func dropSchema(name: String) async throws {
        throw NSError(domain: "PluginDatabaseDriver", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "Drop schema is not supported by this driver"])
    }

    func switchDatabase(to database: String) async throws {
        throw NSError(
            domain: "TableProPluginKit",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "This driver does not support database switching"]
        )
    }

    var currentDatabase: String? { nil }

    func buildBrowseQuery(table: String, sortColumns: [(columnIndex: Int, ascending: Bool)], columns: [String], limit: Int, offset: Int) -> String? { nil }
    func buildFilteredQuery(table: String, filters: [(column: String, op: String, value: String)], logicMode: String, sortColumns: [(columnIndex: Int, ascending: Bool)], columns: [String], limit: Int, offset: Int) -> String? { nil }
    func buildBrowseQuery(table: String, schema: String?, sortColumns: [(columnIndex: Int, ascending: Bool)], columns: [String], limit: Int, offset: Int) -> String? {
        buildBrowseQuery(table: table, sortColumns: sortColumns, columns: columns, limit: limit, offset: offset)
    }
    func buildFilteredQuery(table: String, schema: String?, filters: [(column: String, op: String, value: String)], logicMode: String, sortColumns: [(columnIndex: Int, ascending: Bool)], columns: [String], limit: Int, offset: Int) -> String? {
        buildFilteredQuery(table: table, filters: filters, logicMode: logicMode, sortColumns: sortColumns, columns: columns, limit: limit, offset: offset)
    }
    func buildFilteredQuery(table: String, schema: String?, filters: [(column: String, op: String, value: String)], logicMode: String, sortColumns: [(columnIndex: Int, ascending: Bool)], columns: [String], limit: Int, offset: Int, columnKinds: [String: PluginColumnKind]) -> String? {
        buildFilteredQuery(table: table, schema: schema, filters: filters, logicMode: logicMode, sortColumns: sortColumns, columns: columns, limit: limit, offset: offset)
    }
    func buildFilteredQuery(table: String, schema: String?, queryFilters: [PluginQueryFilter], logicMode: String, sortColumns: [(columnIndex: Int, ascending: Bool)], columns: [String], limit: Int, offset: Int, columnKinds: [String: PluginColumnKind]) -> String? {
        buildFilteredQuery(table: table, schema: schema, filters: queryFilters.asTuples, logicMode: logicMode, sortColumns: sortColumns, columns: columns, limit: limit, offset: offset, columnKinds: columnKinds)
    }
    func fetchFilteredRowCount(table: String, filters: [(column: String, op: String, value: String)], logicMode: String) async throws -> Int? { nil }
    func fetchFilteredRowCount(table: String, queryFilters: [PluginQueryFilter], logicMode: String) async throws -> Int? {
        try await fetchFilteredRowCount(table: table, filters: queryFilters.asTuples, logicMode: logicMode)
    }
    func fetchExactRowCount(table: String, schema: String?, filters: [(column: String, op: String, value: String)], logicMode: String) async throws -> Int? {
        try await fetchFilteredRowCount(table: table, filters: filters, logicMode: logicMode)
    }
    func fetchExactRowCount(table: String, schema: String?, queryFilters: [PluginQueryFilter], logicMode: String) async throws -> Int? {
        try await fetchExactRowCount(table: table, schema: schema, filters: queryFilters.asTuples, logicMode: logicMode)
    }
    func generateStatements(table: String, columns: [String], primaryKeyColumns: [String], changes: [PluginRowChange], insertedRowData: [Int: [PluginCellValue]], deletedRowIndices: Set<Int>, insertedRowIndices: Set<Int>) -> [(statement: String, parameters: [PluginCellValue])]? { nil }
    func generateStatements(table: String, schema: String?, columns: [String], primaryKeyColumns: [String], changes: [PluginRowChange], insertedRowData: [Int: [PluginCellValue]], deletedRowIndices: Set<Int>, insertedRowIndices: Set<Int>) -> [(statement: String, parameters: [PluginCellValue])]? {
        generateStatements(
            table: table, columns: columns, primaryKeyColumns: primaryKeyColumns, changes: changes,
            insertedRowData: insertedRowData, deletedRowIndices: deletedRowIndices, insertedRowIndices: insertedRowIndices
        )
    }
    func generateIdentityPreservingInsert(table: String, schema: String?, columns: [String], primaryKeyColumns: [String], rows: [[PluginCellValue]]) -> [(statement: String, parameters: [PluginCellValue])]? { nil }

    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? { nil }
    func generateModifyColumnSQL(table: String, oldColumn: PluginColumnDefinition, newColumn: PluginColumnDefinition) -> String? { nil }
    func generateDropColumnSQL(table: String, columnName: String) -> String? { nil }
    func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String? { nil }
    func generateDropIndexSQL(table: String, indexName: String) -> String? { nil }
    func generateAddForeignKeySQL(table: String, fk: PluginForeignKeyDefinition) -> String? { nil }
    func generateDropForeignKeySQL(table: String, constraintName: String) -> String? { nil }
    func generateAddCheckConstraintSQL(table: String, constraint: PluginCheckConstraintDefinition) -> String? { nil }
    func generateDropCheckConstraintSQL(table: String, constraintName: String) -> String? { nil }
    func generateRenameCheckConstraintSQL(table: String, from oldName: String, to newName: String) -> String? { nil }
    func generateModifyPrimaryKeySQL(table: String, oldColumns: [String], newColumns: [String], constraintName: String?) -> [String]? { nil }
    func generateMoveColumnSQL(table: String, column: PluginColumnDefinition, afterColumn: String?) -> String? { nil }

    func generateColumnReorderPlan(
        table: String,
        schema: String?,
        columns: [PluginColumnDefinition],
        desiredOrder: [String]
    ) async throws -> PluginColumnReorderPlan? { nil }

    func columnReorderSchemaFingerprint(table: String, schema: String?) async throws -> String? { nil }

    func generateCreateTableSQL(definition: PluginCreateTableDefinition) -> String? { nil }

    func generateColumnDefinitionSQL(column: PluginColumnDefinition) -> String? { nil }
    func generateIndexDefinitionSQL(index: PluginIndexDefinition, tableName: String?) -> String? { nil }
    func generateForeignKeyDefinitionSQL(fk: PluginForeignKeyDefinition) -> String? { nil }

    func truncateTableStatements(table: String, schema: String?, cascade: Bool) -> [String]? { nil }
    func dropObjectStatement(name: String, objectType: String, schema: String?, cascade: Bool) -> String? { nil }
    func foreignKeyDisableStatements() -> [String]? { nil }
    func foreignKeyEnableStatements() -> [String]? { nil }
    func createSchemaStatement(name: String) -> String? { nil }

    func supportedMaintenanceOperations() -> [String]? { nil }
    func maintenanceStatements(operation: String, table: String?, schema: String?, options: [String: String]) -> [String]? { nil }

    func buildExplainQuery(_ sql: String) -> String? { nil }

    func injectRowLimit(_ sql: String, limit: Int) -> String? { nil }

    func createViewTemplate() -> String? { nil }
    func editViewFallbackTemplate(viewName: String) -> String? { nil }
    func castColumnToText(_ column: String) -> String { column }
    func allTablesMetadataSQL(schema: String?) -> String? { nil }
    func defaultExportQuery(table: String) -> String? { nil }
    func defaultExportQuery(table: String, schema: String?) -> String? { defaultExportQuery(table: table) }

    func quoteIdentifier(_ name: String) -> String {
        let escaped = name.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    func executeBoundedQuery(query: String, rowCap: Int) async throws -> PluginQueryResult? { nil }

    /// The bounded read for a driver whose `streamRows` yields rows as they arrive and whose
    /// producer stops when its consumer does. Opt in by returning this from `executeBoundedQuery`.
    ///
    /// The second half of that precondition is the one that gets missed. Terminating the stream
    /// only cancels the task `streamRows` created, so the producer has to be reachable from it and
    /// has to poll: a producer in a nested unstructured `Task {}` never sees the cancel, because a
    /// plain `Task {}` inherits context but is not a child, and a synchronous C paging loop with no
    /// cancellation check never sees it either. A driver that gets this wrong returns early while
    /// its connection stays busy pulling the rest of the result, which is worse than not opting in.
    func boundedQueryFromStream(query: String, rowCap: Int) async throws -> PluginQueryResult {
        try await PluginBoundedStream.collect(
            streamRows(query: query),
            rowCap: rowCap,
            startedAt: Date()
        )
    }

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let result = try await self.execute(query: query)
                    let header = PluginStreamHeader(
                        columns: result.columns,
                        columnTypeNames: result.columnTypeNames
                    )
                    continuation.yield(.header(header))
                    if !result.rows.isEmpty {
                        continuation.yield(.rows(result.rows))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func escapeStringLiteral(_ value: String) -> String {
        var result = value
        result = result.replacingOccurrences(of: "'", with: "''")
        result = result.replacingOccurrences(of: "\0", with: "")
        return result
    }

    func fetchSessionContexts() async throws -> [PluginSessionContext]? { nil }

    func switchSessionContext(id: String, to value: String) async throws {}

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        guard !parameters.isEmpty else {
            return try await execute(query: query)
        }

        let sql: String
        switch parameterStyle {
        case .questionMark:
            sql = substituteQuestionMarks(query: query, parameters: parameters)
        case .dollar:
            sql = substituteDollarParams(query: query, parameters: parameters)
        }

        return try await execute(query: sql)
    }

    private func substituteQuestionMarks(query: String, parameters: [PluginCellValue]) -> String {
        let nsQuery = query as NSString
        let length = nsQuery.length
        var sql = ""
        var paramIndex = 0
        var inSingleQuote = false
        var inDoubleQuote = false
        var isEscaped = false
        var i = 0

        let backslash: UInt16 = 0x5C // \\
        let singleQuote: UInt16 = 0x27 // '
        let doubleQuote: UInt16 = 0x22 // "
        let questionMark: UInt16 = 0x3F // ?

        while i < length {
            let char = nsQuery.character(at: i)

            if isEscaped {
                isEscaped = false
                if let scalar = UnicodeScalar(char) {
                    sql.append(Character(scalar))
                } else {
                    sql.append("\u{FFFD}")
                }
                i += 1
                continue
            }

            if char == backslash && (inSingleQuote || inDoubleQuote) {
                isEscaped = true
                if let scalar = UnicodeScalar(char) {
                    sql.append(Character(scalar))
                } else {
                    sql.append("\u{FFFD}")
                }
                i += 1
                continue
            }

            if char == singleQuote && !inDoubleQuote {
                inSingleQuote.toggle()
            } else if char == doubleQuote && !inSingleQuote {
                inDoubleQuote.toggle()
            }

            if char == questionMark && !inSingleQuote && !inDoubleQuote && paramIndex < parameters.count {
                sql.append(sqlLiteral(for: parameters[paramIndex]))
                paramIndex += 1
            } else {
                if let scalar = UnicodeScalar(char) {
                    sql.append(Character(scalar))
                } else {
                    sql.append("\u{FFFD}")
                }
            }

            i += 1
        }

        return sql
    }

    private func substituteDollarParams(query: String, parameters: [PluginCellValue]) -> String {
        let nsQuery = query as NSString
        let length = nsQuery.length
        var sql = ""
        var i = 0
        var inSingleQuote = false
        var inDoubleQuote = false
        var isEscaped = false

        while i < length {
            let char = nsQuery.character(at: i)

            if isEscaped {
                isEscaped = false
                if let scalar = UnicodeScalar(char) {
                    sql.append(Character(scalar))
                } else {
                    sql.append("\u{FFFD}")
                }
                i += 1
                continue
            }

            let backslash: UInt16 = 0x5C // \\
            if char == backslash && (inSingleQuote || inDoubleQuote) {
                isEscaped = true
                if let scalar = UnicodeScalar(char) {
                    sql.append(Character(scalar))
                } else {
                    sql.append("\u{FFFD}")
                }
                i += 1
                continue
            }

            let singleQuote: UInt16 = 0x27 // '
            let doubleQuote: UInt16 = 0x22 // "
            if char == singleQuote && !inDoubleQuote {
                inSingleQuote.toggle()
            } else if char == doubleQuote && !inSingleQuote {
                inDoubleQuote.toggle()
            }

            let dollar: UInt16 = 0x24 // $
            if char == dollar && !inSingleQuote && !inDoubleQuote {
                var numStr = ""
                var j = i + 1
                while j < length {
                    let digitChar = nsQuery.character(at: j)
                    if digitChar >= 0x30 && digitChar <= 0x39 { // 0-9
                        if let scalar = UnicodeScalar(digitChar) {
                            numStr.append(Character(scalar))
                        }
                        j += 1
                    } else {
                        break
                    }
                }
                if !numStr.isEmpty, let paramNum = Int(numStr), paramNum >= 1, paramNum <= parameters.count {
                    sql.append(sqlLiteral(for: parameters[paramNum - 1]))
                    i = j
                    continue
                }
            }

            if let scalar = UnicodeScalar(char) {
                sql.append(Character(scalar))
            } else {
                sql.append("\u{FFFD}")
            }
            i += 1
        }

        return sql
    }

    func sqlLiteral(for value: PluginCellValue) -> String {
        switch value {
        case .null:
            return "NULL"
        case .text(let s):
            return escapedParameterValue(s)
        case .bytes(let data):
            var hex = "X'"
            hex.reserveCapacity(2 + data.count * 2 + 1)
            for byte in data {
                hex.append(String(format: "%02X", byte))
            }
            hex.append("'")
            return hex
        }
    }

    func escapedParameterValue(_ value: String) -> String {
        if Self.isNumericLiteral(value) {
            return value
        }
        var escaped = ""
        escaped.reserveCapacity(value.count + 2)
        escaped.append("'")
        let escapeBackslashes = requiresBackslashEscapingInLiterals
        for char in value {
            switch char {
            case "'":
                escaped.append("''")
            case "\0":
                continue
            case "\\" where escapeBackslashes:
                escaped.append("\\\\")
            case "\n" where escapeBackslashes:
                escaped.append("\\n")
            case "\r" where escapeBackslashes:
                escaped.append("\\r")
            case "\t" where escapeBackslashes:
                escaped.append("\\t")
            case "\u{1A}" where escapeBackslashes:
                escaped.append("\\Z")
            default:
                escaped.append(char)
            }
        }
        escaped.append("'")
        return escaped
    }

    static func isNumericLiteral(_ value: String) -> Bool {
        PluginNumericLiteral.isValid(value)
    }

    func executeUserQuery(query: String, rowCap: Int?, parameters: [PluginCellValue]?) async throws -> PluginQueryResult {
        let raw: PluginQueryResult
        if let parameters {
            raw = try await executeParameterized(query: query, parameters: parameters)
        } else {
            raw = try await execute(query: query)
        }
        guard let cap = rowCap, cap > 0, raw.rows.count > cap else {
            return raw
        }
        return PluginQueryResult(
            columns: raw.columns,
            columnTypeNames: raw.columnTypeNames,
            rows: Array(raw.rows.prefix(cap)),
            rowsAffected: raw.rowsAffected,
            executionTime: raw.executionTime,
            isTruncated: true,
            statusMessage: raw.statusMessage
        )
    }
}

public enum PluginSQLFilter {
    public static func escapeForLike(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
            .replacingOccurrences(of: "'", with: "''")
    }

    public static func buildOrderByClause(
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        quoteIdentifier: (String) -> String
    ) -> String? {
        let parts = sortColumns.compactMap { sortCol -> String? in
            guard sortCol.columnIndex >= 0, sortCol.columnIndex < columns.count else { return nil }
            let direction = sortCol.ascending ? "ASC" : "DESC"
            return "\(quoteIdentifier(columns[sortCol.columnIndex])) \(direction)"
        }
        guard !parts.isEmpty else { return nil }
        return "ORDER BY " + parts.joined(separator: ", ")
    }

    public static func buildWhereClause(
        filters: [(column: String, op: String, value: String)],
        logicMode: String,
        quoteIdentifier: (String) -> String,
        escapeValue: (String) -> String,
        regexCondition: (_ quotedColumn: String, _ value: String) -> String?
    ) -> String {
        let conditions = filters.compactMap { filter in
            buildFilterCondition(
                column: filter.column,
                op: filter.op,
                value: filter.value,
                quoteIdentifier: quoteIdentifier,
                escapeValue: escapeValue,
                regexCondition: regexCondition
            )
        }
        guard !conditions.isEmpty else { return "" }
        let separator = logicMode == "and" ? " AND " : " OR "
        return conditions.joined(separator: separator)
    }

    public static func buildFilterCondition(
        column: String,
        op: String,
        value: String,
        quoteIdentifier: (String) -> String,
        escapeValue: (String) -> String,
        regexCondition: (_ quotedColumn: String, _ value: String) -> String?
    ) -> String? {
        let quoted = quoteIdentifier(column)
        switch op {
        case "=": return "\(quoted) = \(escapeValue(value))"
        case "!=": return "\(quoted) != \(escapeValue(value))"
        case ">": return "\(quoted) > \(escapeValue(value))"
        case ">=": return "\(quoted) >= \(escapeValue(value))"
        case "<": return "\(quoted) < \(escapeValue(value))"
        case "<=": return "\(quoted) <= \(escapeValue(value))"
        case "IS NULL": return "\(quoted) IS NULL"
        case "IS NOT NULL": return "\(quoted) IS NOT NULL"
        case "IS EMPTY": return "(\(quoted) IS NULL OR \(quoted) = '')"
        case "IS NOT EMPTY": return "(\(quoted) IS NOT NULL AND \(quoted) != '')"
        case "CONTAINS":
            return "\(quoted) LIKE '%\(escapeForLike(value))%' ESCAPE '\\'"
        case "NOT CONTAINS":
            return "\(quoted) NOT LIKE '%\(escapeForLike(value))%' ESCAPE '\\'"
        case "STARTS WITH":
            return "\(quoted) LIKE '\(escapeForLike(value))%' ESCAPE '\\'"
        case "ENDS WITH":
            return "\(quoted) LIKE '%\(escapeForLike(value))' ESCAPE '\\'"
        case "IN":
            let values = value.split(separator: ",")
                .map { escapeValue($0.trimmingCharacters(in: .whitespaces)) }
                .joined(separator: ", ")
            return values.isEmpty ? nil : "\(quoted) IN (\(values))"
        case "NOT IN":
            let values = value.split(separator: ",")
                .map { escapeValue($0.trimmingCharacters(in: .whitespaces)) }
                .joined(separator: ", ")
            return values.isEmpty ? nil : "\(quoted) NOT IN (\(values))"
        case "BETWEEN":
            let parts = value.split(separator: ",", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let v1 = escapeValue(parts[0].trimmingCharacters(in: .whitespaces))
            let v2 = escapeValue(parts[1].trimmingCharacters(in: .whitespaces))
            return "\(quoted) BETWEEN \(v1) AND \(v2)"
        case "REGEX":
            return regexCondition(quoted, value)
        default: return nil
        }
    }

    public static func buildWhereClause(
        filters: [(column: String, op: String, value: String)],
        logicMode: String,
        columnKinds: [String: PluginColumnKind],
        quoteIdentifier: (String) -> String,
        escapeTypedValue: (_ value: String, _ kind: PluginColumnKind?) -> String,
        regexCondition: (_ quotedColumn: String, _ value: String) -> String?
    ) -> String {
        let conditions = filters.compactMap { filter in
            buildFilterCondition(
                column: filter.column,
                op: filter.op,
                value: filter.value,
                kind: columnKinds[filter.column],
                quoteIdentifier: quoteIdentifier,
                escapeTypedValue: escapeTypedValue,
                regexCondition: regexCondition
            )
        }
        guard !conditions.isEmpty else { return "" }
        let separator = logicMode == "and" ? " AND " : " OR "
        return conditions.joined(separator: separator)
    }

    public static func buildFilterCondition(
        column: String,
        op: String,
        value: String,
        kind: PluginColumnKind?,
        quoteIdentifier: (String) -> String,
        escapeTypedValue: (_ value: String, _ kind: PluginColumnKind?) -> String,
        regexCondition: (_ quotedColumn: String, _ value: String) -> String?
    ) -> String? {
        let quoted = quoteIdentifier(column)
        switch op {
        case "IS EMPTY":
            guard PluginSQLLiteral.supportsEmptyStringComparison(kind) else { return "\(quoted) IS NULL" }
            return "(\(quoted) IS NULL OR \(quoted) = '')"
        case "IS NOT EMPTY":
            guard PluginSQLLiteral.supportsEmptyStringComparison(kind) else { return "\(quoted) IS NOT NULL" }
            return "(\(quoted) IS NOT NULL AND \(quoted) != '')"
        default:
            return buildFilterCondition(
                column: column,
                op: op,
                value: value,
                quoteIdentifier: quoteIdentifier,
                escapeValue: { escapeTypedValue($0, kind) },
                regexCondition: regexCondition
            )
        }
    }
}
