//
//  SQLitePlugin.swift
//  TablePro
//

import CSQLite
import Foundation
import os
import TableProPluginKit

final class SQLitePlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "SQLite Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "SQLite file-based database support"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let explainVariants: [ExplainVariant] = [
        ExplainVariant(
            id: "explain", label: "Explain", sqlPrefix: "EXPLAIN QUERY PLAN", format: .sqliteQueryPlan
        )
    ]

    static let databaseTypeId = "SQLite"
    static let databaseDisplayName = "SQLite"
    static let iconName = "sqlite-icon"
    static let defaultPort = 0

    // MARK: - UI/Capability Metadata

    static let requiresAuthentication = false
    static let supportsSSH = false
    static let supportsSSL = false
    static let isDownloadable = false
    static let pathFieldRole: PathFieldRole = .filePath
    static let connectionMode: ConnectionMode = .fileBased
    static let supportsHealthMonitor = false
    static let urlSchemes: [String] = ["sqlite"]
    static let fileExtensions: [String] = ["db", "db3", "s3db", "sl3", "sqlite", "sqlite3", "sqlitedb"]
    static let brandColorHex = "#003B57"
    static let supportsDatabaseSwitching = false
    static let supportsRenameTable = true
    static let supportsRenameView = false
    static let supportsTriggers = true
    static let supportsDatabaseTriggerBrowse = true
    static let supportsTriggerEditing = true
    static let structureColumnFields: [StructureColumnField] =
        [.name, .type, .nullable, .defaultValue, .generated, .generationExpression, .autoIncrement]

    static let supportsCheckConstraints = true

    static let additionalConnectionFields: [ConnectionField] = [.loadableExtensions()]

    /// ALTER TABLE ... ADD/DROP CONSTRAINT arrived in SQLite 3.53.0 (2026-04-09). The plugin links
    /// its own SQLite (scripts/build-sqlite.sh), so this follows the version pinned there rather
    /// than the user's macOS.
    static let supportsCheckConstraintEditing = sqlite3_libversion_number() >= 3_053_000

    static let supportsGeneratedColumns = true
    static let databaseGroupingStrategy: GroupingStrategy = .flat
    static let columnTypesByCategory: [String: [String]] = [
        "Integer": ["INTEGER", "INT", "TINYINT", "SMALLINT", "MEDIUMINT", "BIGINT"],
        "Float": ["REAL", "DOUBLE", "FLOAT", "NUMERIC", "DECIMAL"],
        "String": ["TEXT", "VARCHAR", "CHARACTER", "CHAR", "CLOB", "NVARCHAR", "NCHAR"],
        "Date": ["DATE", "TIME", "DATETIME", "TIMESTAMP"],
        "Binary": ["BLOB"],
        "Boolean": ["BOOLEAN"]
    ]

    static let sqlDialect: SQLDialectDescriptor? = SQLDialectDescriptor(
        identifierQuote: "`",
        keywords: [
            "SELECT", "FROM", "WHERE", "JOIN", "INNER", "LEFT", "RIGHT", "OUTER", "CROSS",
            "ON", "AND", "OR", "NOT", "IN", "LIKE", "GLOB", "BETWEEN", "AS",
            "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "OFFSET",
            "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
            "CREATE", "ALTER", "DROP", "TABLE", "INDEX", "VIEW", "TRIGGER",
            "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "CONSTRAINT",
            "ADD", "COLUMN", "RENAME",
            "NULL", "IS", "ASC", "DESC", "DISTINCT", "ALL",
            "CASE", "WHEN", "THEN", "ELSE", "END", "COALESCE", "IFNULL", "NULLIF",
            "UNION", "INTERSECT", "EXCEPT",
            "AUTOINCREMENT", "WITHOUT", "ROWID", "PRAGMA",
            "REPLACE", "ABORT", "FAIL", "IGNORE", "ROLLBACK",
            "TEMP", "TEMPORARY", "VACUUM", "EXPLAIN", "QUERY", "PLAN"
        ],
        functions: [
            "COUNT", "SUM", "AVG", "MAX", "MIN", "GROUP_CONCAT", "TOTAL",
            "LENGTH", "SUBSTR", "SUBSTRING", "LOWER", "UPPER", "TRIM", "LTRIM", "RTRIM",
            "REPLACE", "INSTR", "PRINTF",
            "DATE", "TIME", "DATETIME", "JULIANDAY", "STRFTIME",
            "ABS", "ROUND", "RANDOM",
            "CAST", "TYPEOF",
            "COALESCE", "IFNULL", "NULLIF", "HEX", "QUOTE"
        ],
        dataTypes: [
            "INTEGER", "REAL", "TEXT", "BLOB", "NUMERIC",
            "INT", "TINYINT", "SMALLINT", "MEDIUMINT", "BIGINT",
            "UNSIGNED", "BIG", "INT2", "INT8",
            "CHARACTER", "VARCHAR", "VARYING", "NCHAR", "NATIVE",
            "NVARCHAR", "CLOB",
            "DOUBLE", "PRECISION", "FLOAT",
            "DECIMAL", "BOOLEAN", "DATE", "DATETIME"
        ],
        tableOptions: [
            "WITHOUT ROWID", "STRICT"
        ],
        regexSyntax: .unsupported,
        booleanLiteralStyle: .numeric,
        likeEscapeStyle: .explicit,
        paginationStyle: .limit,
        caseSensitivityStyle: .collationDefined
    )

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        SQLitePluginDriver(config: config)
    }
}

// MARK: - SQLite Plugin Driver

final class SQLitePluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let config: DriverConnectionConfig
    private let backend: any SQLiteExecutionBackend

    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLitePluginDriver")

    var currentSchema: String? { nil }
    var serverVersion: String? { backend.resolvedServerVersion }
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { true }

    func sessionTransactionState() async -> PluginSessionTransactionState {
        await backend.sessionTransactionState()
    }

    var capabilities: PluginCapabilities {
        [
            .parameterizedQueries,
            .transactions,
            .alterTableDDL,
            .foreignKeyToggle,
            .truncateTable,
            .cancelQuery,
            .batchExecute,
            .schemaCompare,
            .dataCompare,
        ]
    }

    func quoteIdentifier(_ name: String) -> String {
        sqliteQuoteIdentifier(name)
    }

    init(config: DriverConnectionConfig) {
        self.config = config
        self.backend = Self.makeBackend(config: config)
    }

    /// A file-backed connection runs on the app's own SQLite; one whose transport marks it a remote
    /// session runs on the server's SQLite through the agent. The mark and the token are set by the
    /// app's transport when it rewrites the effective connection, never by the user.
    private static func makeBackend(config: DriverConnectionConfig) -> any SQLiteExecutionBackend {
        guard config.additionalFields[SQLiteAgentProtocol.backendFieldKey] == SQLiteAgentProtocol.agentBackendValue else {
            return SQLiteLocalBackend(path: config.database)
        }
        return SQLiteAgentBackend(
            host: config.host.isEmpty ? "127.0.0.1" : config.host,
            port: config.port,
            path: config.database,
            token: config.additionalFields[SQLiteAgentProtocol.tokenFieldKey] ?? ""
        )
    }

    // MARK: - Connection

    func connect() async throws {
        let extensions = try LoadableExtensionList.decode(config.additionalFields[LoadableExtensionList.fieldId])
        try await withTaskCancellationHandler {
            try await backend.open(loading: extensions)
        } onCancel: {
            backend.abortConnect()
        }
    }

    func disconnect() {
        let backend = self.backend
        Task { await backend.close() }
    }

    func ping() async throws {
        _ = try await execute(query: "SELECT 1")
    }

    func applyQueryTimeout(_ seconds: Int) async throws {
        await backend.applyBusyTimeout(Int32(max(0, seconds) * 1_000))
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> PluginQueryResult {
        let rawResult = try await backend.executeQuery(query)
        return PluginQueryResult(
            columns: rawResult.columns,
            columnTypeNames: rawResult.columnTypeNames,
            rows: rawResult.rows,
            rowsAffected: rawResult.rowsAffected,
            executionTime: rawResult.executionTime,
            isTruncated: rawResult.isTruncated
        )
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        let rawResult = try await backend.executeParameterizedQuery(query, parameters: parameters)
        return PluginQueryResult(
            columns: rawResult.columns,
            columnTypeNames: rawResult.columnTypeNames,
            rows: rawResult.rows,
            rowsAffected: rawResult.rowsAffected,
            executionTime: rawResult.executionTime,
            isTruncated: rawResult.isTruncated
        )
    }

    /// `sqlite3_interrupt` ends a statement that is running. A connection waiting for a lock is
    /// not running one, and measurably ignores it, so the busy handler is what ends that wait. The
    /// remote backend forwards the same intent to the agent as a cancel frame.
    func cancelQuery() throws {
        backend.canceller.cancel()
    }

    // MARK: - EXPLAIN

    func buildExplainQuery(_ sql: String) -> String? {
        "EXPLAIN QUERY PLAN \(sql)"
    }

    // MARK: - Maintenance

    func supportedMaintenanceOperations() -> [String]? {
        SQLiteMaintenance.operations.map(\.name)
    }

    func maintenanceOperations() -> [PluginMaintenanceOperation]? {
        SQLiteMaintenance.operations
    }

    func maintenanceStatements(operation: String, table: String?, schema: String?, options: [String: String]) -> [String]? {
        SQLiteMaintenance.statements(operation: operation, table: table)
    }

    // MARK: - View Templates

    func createViewTemplate() -> String? {
        "CREATE VIEW IF NOT EXISTS view_name AS\nSELECT column1, column2\nFROM table_name\nWHERE condition;"
    }

    func editViewFallbackTemplate(viewName: String) -> String? {
        let quoted = quoteIdentifier(viewName)
        return "DROP VIEW IF EXISTS \(quoted);\nCREATE VIEW \(quoted) AS\nSELECT * FROM table_name;"
    }

    // MARK: - Foreign Key Checks

    func foreignKeyDisableStatements() -> [String]? {
        ["PRAGMA foreign_keys = OFF"]
    }

    func foreignKeyEnableStatements() -> [String]? {
        ["PRAGMA foreign_keys = ON"]
    }

    // MARK: - User Query

    func executeBoundedQuery(query: String, rowCap: Int) async throws -> PluginQueryResult? {
        guard Self.returnsRows(query) else { return nil }
        return try await boundedQueryFromStream(query: query, rowCap: rowCap)
    }

    /// A capped read from a caller that resolves its own cap, the MCP bridge among them, still
    /// streams. Routing every uncapped statement through the stream is what made a DML statement
    /// report no row count, because a stepped statement carries its `sqlite3_changes` nowhere.
    func executeUserQuery(query: String, rowCap: Int?, parameters: [PluginCellValue]?) async throws -> PluginQueryResult {
        if parameters == nil, let cap = rowCap, cap > 0,
           let bounded = try await executeBoundedQuery(query: query, rowCap: cap) {
            return bounded
        }

        let raw: PluginQueryResult
        if let parameters {
            raw = try await executeParameterized(query: query, parameters: parameters)
        } else {
            raw = try await execute(query: query)
        }
        guard let cap = rowCap, cap > 0, raw.rows.count > cap else { return raw }
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

    private static let rowReturningKeywords: Set<String> = ["SELECT", "WITH", "VALUES", "TABLE", "PRAGMA", "EXPLAIN"]

    private static func returnsRows(_ query: String) -> Bool {
        var remaining = Substring(query).drop { $0.isWhitespace }
        while remaining.first == "(" {
            remaining = remaining.dropFirst().drop { $0.isWhitespace }
        }
        let keyword = remaining.prefix { $0.isLetter }.uppercased()
        return rowReturningKeywords.contains(keyword)
    }

    // MARK: - Schema Operations

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        let query = """
            SELECT name, type FROM sqlite_master
            WHERE type IN ('table', 'view')
            AND name NOT LIKE 'sqlite_%'
            ORDER BY name
        """
        let result = try await execute(query: query)
        return result.rows.compactMap { row in
            guard let name = row[safe: 0]?.asText else { return nil }
            let typeString = row[safe: 1]?.asText ?? "table"
            let tableType = typeString.lowercased() == "view" ? "VIEW" : "TABLE"
            return PluginTableInfo(name: name, type: tableType)
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let safeTable = escapeStringLiteral(table)
        // table_xinfo rather than table_info: table_info omits generated columns entirely, so they
        // were invisible to the structure editor and to every write path that reads this list.
        let query = "PRAGMA table_xinfo('\(safeTable)')"
        let result = try await execute(query: query)
        let generationExpressions = SQLiteCheckConstraintParser.generationExpressions(
            inCreateStatement: try await createStatement(forTable: table) ?? ""
        )

        return result.rows.compactMap { row in
            guard row.count >= 7,
                  let name = row[1].asText,
                  let dataType = row[2].asText else {
                return nil
            }

            // hidden: 0 normal, 1 a virtual table's hidden column, 2 VIRTUAL generated,
            // 3 STORED generated.
            let hidden = row[6].asText.flatMap { Int($0) } ?? 0
            guard hidden != 1 else { return nil }

            let isNullable = row[3].asText == "0"
            // PRAGMA pk column: 0 = not PK, 1+ = position in composite PK
            let pkText = row[5].asText
            let isPrimaryKey = pkText != nil && pkText != "0"
            let defaultValue = sqliteDefaultValueFromCatalog(row[4].asText)
            let generationKind: GenerationKind? = hidden == 2 ? .virtual : (hidden == 3 ? .stored : nil)

            return PluginColumnInfo(
                name: name,
                dataType: dataType,
                isNullable: isNullable,
                isPrimaryKey: isPrimaryKey,
                defaultValue: defaultValue,
                isGenerated: generationKind != nil,
                generationExpression: generationKind == nil ? nil : generationExpressions[name],
                generationKind: generationKind
            )
        }
    }

    private func createStatement(forTable table: String) async throws -> String? {
        let query = "SELECT sql FROM sqlite_master WHERE type='table' AND name='\(escapeStringLiteral(table))'"
        let result = try await execute(query: query)
        return result.rows.first?[safe: 0]?.asText
    }

    func fetchCheckConstraints(table: String, schema: String?) async throws -> [PluginCheckConstraintInfo] {
        guard let statement = try await createStatement(forTable: table) else { return [] }
        return SQLiteCheckConstraintParser.constraints(inCreateStatement: statement).map { parsed in
            PluginCheckConstraintInfo(name: parsed.name, expression: parsed.expression)
        }
    }

    var providesBulkColumnFetch: Bool { true }

    /// `pragma_table_xinfo`, not `pragma_table_info`, for the same reason `fetchColumns` uses it:
    /// `table_info` omits generated columns entirely, so the bulk read used to answer with a
    /// shorter column list than the per-table read for the same table. A caller comparing two
    /// schemas through the bulk read saw neither side's generated columns and reported them as
    /// matching. `m.sql` rides along so the generation expressions are parsed from the CREATE
    /// statement without a second round trip per table.
    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        let query = """
            SELECT m.name AS tbl, p.cid, p.name, p.type, p."notnull", p.dflt_value, p.pk,
                   p.hidden, m.sql
            FROM sqlite_master m, pragma_table_xinfo(m.name) p
            WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite_%'
            ORDER BY m.name, p.cid
            """
        let result = try await execute(query: query)

        var allColumns: [String: [PluginColumnInfo]] = [:]
        var expressionsByTable: [String: [String: String]] = [:]

        for row in result.rows {
            guard row.count >= 9,
                  let tableName = row[0].asText,
                  let columnName = row[2].asText,
                  let dataType = row[3].asText else {
                continue
            }

            // hidden: 0 normal, 1 a virtual table's hidden column, 2 VIRTUAL generated,
            // 3 STORED generated.
            let hidden = row[7].asText.flatMap { Int($0) } ?? 0
            guard hidden != 1 else { continue }

            let isNullable = row[4].asText == "0"
            let defaultValue = sqliteDefaultValueFromCatalog(row[5].asText)
            // PRAGMA table_xinfo pk column: 0 = not PK, 1+ = position in composite PK
            let pkText = row[6].asText
            let isPrimaryKey = pkText != nil && pkText != "0"
            let generationKind: GenerationKind? = hidden == 2 ? .virtual : (hidden == 3 ? .stored : nil)

            if generationKind != nil, expressionsByTable[tableName] == nil {
                expressionsByTable[tableName] = SQLiteCheckConstraintParser.generationExpressions(
                    inCreateStatement: row[8].asText ?? ""
                )
            }

            let column = PluginColumnInfo(
                name: columnName,
                dataType: dataType,
                isNullable: isNullable,
                isPrimaryKey: isPrimaryKey,
                defaultValue: defaultValue,
                isGenerated: generationKind != nil,
                generationExpression: generationKind == nil ? nil : expressionsByTable[tableName]?[columnName],
                generationKind: generationKind
            )

            allColumns[tableName, default: []].append(column)
        }

        return allColumns
    }

    var providesBulkForeignKeyFetch: Bool { true }

    var tableDDLIncludesForeignKeys: Bool { true }

    func fetchAllForeignKeys(schema: String?) async throws -> [String: [PluginForeignKeyInfo]] {
        /// Selected in `PRAGMA foreign_key_list`'s own column order, behind the table name, so the
        /// rows can be handed to the same grouping the single-table read uses.
        let query = """
            SELECT m.name AS table_name, p.id, p.seq, p."table", p."from", p."to",
                   p.on_update, p.on_delete
            FROM sqlite_master m, pragma_foreign_key_list(m.name) p
            WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite_%'
            ORDER BY m.name, p.id, p.seq
            """
        let result = try await execute(query: query)

        var pragmaRowsByTable: [String: [[PluginCellValue]]] = [:]
        for row in result.rows {
            guard row.count >= 8, let tableName = row[0].asText else { continue }
            pragmaRowsByTable[tableName, default: []].append(Array(row.dropFirst()))
        }
        guard !pragmaRowsByTable.isEmpty else { return [:] }

        let createStatements = try await createTableStatements()
        /// One query for every parent the whole database references, rather than one per table.
        /// Omitting it made a shorthand `REFERENCES parent` resolve to the child's own column name.
        let primaryKeysByTable = try await primaryKeys(
            ofTablesReferencedIn: SQLiteForeignKeyParents.referencedTables(in: pragmaRowsByTable)
        )
        return pragmaRowsByTable.reduce(into: [:]) { foreignKeys, entry in
            foreignKeys[entry.key] = SQLiteForeignKeyGrouping.infos(
                table: entry.key,
                pragmaRows: entry.value,
                createTableSQL: createStatements[entry.key],
                primaryKeysByTable: primaryKeysByTable
            )
        }
    }

    /// The stored `CREATE TABLE` text for every ordinary table, keyed by name. Read in one query so
    /// recovering constraint names costs one round trip rather than one per table.
    private func createTableStatements() async throws -> [String: String] {
        let rows = try await execute(query: """
            SELECT name, sql FROM sqlite_master
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND sql IS NOT NULL
            """).rows
        return rows.reduce(into: [:]) { statements, row in
            guard let name = row[safe: 0]?.asText, let sql = row[safe: 1]?.asText else { return }
            statements[name] = sql
        }
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        let result = try await execute(query: SQLiteIndexCatalog.indexesQuery(table: table))
        return SQLiteIndexCatalog.indexes(fromRows: result.rows)
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        let safeTable = escapeStringLiteral(table)
        let pragmaRows = try await execute(query: "PRAGMA foreign_key_list('\(safeTable)')").rows
        guard !pragmaRows.isEmpty else { return [] }

        let createTableSQL = try await execute(query: """
            SELECT sql FROM sqlite_master WHERE type = 'table' AND name = '\(safeTable)'
            """).rows.first?[safe: 0]?.asText

        return SQLiteForeignKeyGrouping.infos(
            table: table,
            pragmaRows: pragmaRows,
            createTableSQL: createTableSQL,
            primaryKeysByTable: try await primaryKeys(
                ofTablesReferencedIn: SQLiteForeignKeyParents.referencedTables(in: pragmaRows)
            )
        )
    }

    /// The primary key columns of each named table, in key order, keyed by lower-cased table name.
    ///
    /// A foreign key written `REFERENCES parent` with no column list points at the parent's primary
    /// key, and `PRAGMA foreign_key_list` reports null rather than resolving it, so the parent has
    /// to be asked. One query covers every parent a table references.
    private func primaryKeys(ofTablesReferencedIn tables: [String]) async throws -> [String: [String]] {
        let names = Set(tables.map { $0.lowercased() })
        guard !names.isEmpty else { return [:] }
        let literals = names.map { "'\(escapeStringLiteral($0))'" }.joined(separator: ", ")

        let rows = try await execute(query: """
            SELECT m.name, i.name
            FROM sqlite_master m, pragma_table_info(m.name) i
            WHERE m.type = 'table' AND lower(m.name) IN (\(literals)) AND i.pk > 0
            ORDER BY m.name, i.pk
            """).rows

        return rows.reduce(into: [:]) { keys, row in
            guard let table = row[safe: 0]?.asText, let column = row[safe: 1]?.asText else { return }
            keys[table.lowercased(), default: []].append(column)
        }
    }

    func fetchTriggers(table: String, schema: String?) async throws -> [PluginTriggerInfo] {
        try await sqliteTriggerList(table: table)
    }

    var supportsTransactionalDDL: Bool { true }

    func createTriggerTemplate(table: String, schema: String?) -> String? {
        """
        CREATE TRIGGER \(quoteIdentifier("trigger_name"))
        AFTER INSERT ON \(quoteIdentifier(table))
        BEGIN
            -- INSERT INTO audit ...;
        END;
        """
    }

    func generateDropTriggerSQL(name: String, table: String, schema: String?) -> String? {
        "DROP TRIGGER IF EXISTS \(quoteIdentifier(name))"
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let safeTable = escapeStringLiteral(table)
        let query = """
            SELECT sql FROM sqlite_master
            WHERE type = 'table' AND name = '\(safeTable)'
            """
        let result = try await execute(query: query)

        guard let firstRow = result.rows.first,
              let ddl = firstRow[0].asText else {
            throw SQLitePluginError.queryFailed("Failed to fetch DDL for table '\(table)'")
        }

        let formatted = formatDDL(ddl)
        return formatted.hasSuffix(";") ? formatted : formatted + ";"
    }

    /// `sqlite_master` stores each index's own `CREATE INDEX` text, which is what `sqlite3 .dump`
    /// replays and which carries a partial predicate, an expression key, a collation and a sort
    /// direction exactly as written. An index SQLite created for itself to back a UNIQUE or PRIMARY
    /// KEY constraint has a null `sql`, so testing for that is what keeps `sqlite_autoindex_*` out
    /// of the dump: those come back with the constraint inside `CREATE TABLE`.
    func fetchIndexDDL(table: String, schema: String?) async throws -> [String] {
        let result = try await execute(query: """
            SELECT sql FROM sqlite_master
            WHERE type = 'index'
              AND tbl_name = '\(escapeStringLiteral(table))'
              AND sql IS NOT NULL
            ORDER BY name
            """)
        return result.rows.compactMap { $0[safe: 0]?.asText }
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        let safeView = escapeStringLiteral(view)
        let query = """
            SELECT sql FROM sqlite_master
            WHERE type = 'view' AND name = '\(safeView)'
            """
        let result = try await execute(query: query)

        guard let firstRow = result.rows.first,
              let ddl = firstRow[0].asText else {
            throw SQLitePluginError.queryFailed("Failed to fetch definition for view '\(view)'")
        }

        return ddl
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        let safeTableName = table.replacingOccurrences(of: "\"", with: "\"\"")
        let countQuery = "SELECT COUNT(*) FROM (SELECT 1 FROM \"\(safeTableName)\" LIMIT 100001)"
        let countResult = try await execute(query: countQuery)
        let rowCount: Int64? = {
            guard let row = countResult.rows.first, let firstCell = row.first else { return nil }
            return Int64(firstCell.asText ?? "0")
        }()

        return PluginTableMetadata(
            tableName: table,
            rowCount: rowCount,
            engine: "SQLite"
        )
    }

    func fetchDatabases() async throws -> [String] {
        []
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }

    // MARK: - All Tables Metadata

    func allTablesMetadataSQL(schema: String?) -> String? {
        """
        SELECT
            '' as schema,
            name,
            type as kind,
            '' as charset,
            '' as collation,
            '' as estimated_rows,
            '' as total_size,
            '' as data_size,
            '' as index_size,
            '' as comment
        FROM sqlite_master
        WHERE type IN ('table', 'view')
        AND name NOT LIKE 'sqlite_%'
        ORDER BY name
        """
    }

    // MARK: - Streaming

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        let queryToRun = String(query)
        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let streamTask = Task {
                do {
                    try await self.backend.streamQuery(queryToRun, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                streamTask.cancel()
            }
        }
    }

    // MARK: - Create Table DDL

    func generateCreateTableSQL(definition: PluginCreateTableDefinition) -> String? {
        sqliteCreateTableSQL(definition: definition)
    }

    /// Kept as a method because the table-rebuild path renders its columns through it. The body is
    /// the extracted free function, so the create path and the rebuild path cannot spell a column
    /// two different ways.
    func sqliteColumnDefinition(_ column: PluginColumnDefinition, inlinePK: Bool) -> String {
        sqliteColumnDefinitionSQL(column, isInlinePrimaryKey: inlinePK && column.isPrimaryKey)
    }

    // MARK: - ALTER TABLE DDL

    /// `ALTER TABLE` is the only rename SQLite has and it refuses a view, so a view is turned
    /// away here rather than by a message from the engine. From 3.25 the statement rewrites the
    /// references to the table in every trigger and view, and from 3.26 in every foreign key,
    /// unless `PRAGMA legacy_alter_table` is on.
    func renameTable(name: String, schema: String?, to newName: String, objectType: String) async throws {
        guard objectType.uppercased() == "TABLE" else {
            throw PluginDriverUnsupportedOperation.renameTable
        }
        _ = try await execute(
            query: "ALTER TABLE \(quoteIdentifier(name)) RENAME TO \(quoteIdentifier(newName))"
        )
    }

    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        let colDef = sqliteColumnDefinitionSQL(addableColumn(column), isInlinePrimaryKey: false)
        return "ALTER TABLE \(quoteIdentifier(table)) ADD COLUMN \(colDef)"
    }

    /// ALTER TABLE ADD COLUMN refuses a STORED generated column outright once the table holds rows
    /// ("cannot add a STORED column"), so the ALTER path downgrades to VIRTUAL. CREATE TABLE has no
    /// such limit and keeps whichever kind was chosen.
    private func addableColumn(_ column: PluginColumnDefinition) -> PluginColumnDefinition {
        guard column.generationKind == .stored else { return column }
        return PluginColumnDefinition(
            name: column.name,
            dataType: column.dataType,
            isNullable: column.isNullable,
            defaultValue: column.defaultValue,
            isPrimaryKey: column.isPrimaryKey,
            autoIncrement: column.autoIncrement,
            comment: column.comment,
            unsigned: column.unsigned,
            onUpdate: column.onUpdate,
            charset: column.charset,
            collation: column.collation,
            generationExpression: column.generationExpression,
            generationKind: .virtual
        )
    }

    func generateModifyColumnSQL(table: String, oldColumn: PluginColumnDefinition, newColumn: PluginColumnDefinition) -> String? {
        guard oldColumn.name != newColumn.name else { return nil }
        return "ALTER TABLE \(quoteIdentifier(table)) RENAME COLUMN \(quoteIdentifier(oldColumn.name)) TO \(quoteIdentifier(newColumn.name))"
    }

    func generateDropColumnSQL(table: String, columnName: String) -> String? {
        "ALTER TABLE \(quoteIdentifier(table)) DROP COLUMN \(quoteIdentifier(columnName))"
    }

    /// SQLite has no positional `ALTER`, so the order changes by rebuilding the table.
    ///
    /// The new table is written by moving the original column definitions as text inside the
    /// statement SQLite stored, so a `CHECK`, a `COLLATE`, a `GENERATED ALWAYS AS` and a `DEFAULT`
    /// with a comma in it all come through untouched. Re-rendering them from `PRAGMA table_info`
    /// would lose every one, because the pragma does not report them.
    func generateColumnReorderPlan(
        table: String,
        schema: String?,
        columns: [PluginColumnDefinition],
        desiredOrder: [String]
    ) async throws -> PluginColumnReorderPlan? {
        try await SQLiteColumnReorderPlanner.plan(
            tableName: table,
            desiredOrder: desiredOrder,
            isRunnable: true,
            execute: { try await self.execute(query: $0) }
        )
    }

    func columnReorderSchemaFingerprint(table: String, schema: String?) async throws -> String? {
        try await SQLiteColumnReorderPlanner.schemaFingerprint(
            tableName: table,
            execute: { try await self.execute(query: $0) }
        )
    }

    /// ADD/DROP CONSTRAINT arrived in SQLite 3.53.0. Returning nil below that version makes
    /// `SchemaStatementGenerator` refuse the change with "Unsupported schema operation" rather than
    /// sending a statement the linked library cannot parse.
    func generateAddCheckConstraintSQL(table: String, constraint: PluginCheckConstraintDefinition) -> String? {
        guard SQLitePlugin.supportsCheckConstraintEditing else { return nil }
        let expression = constraint.expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty, !constraint.name.isEmpty else { return nil }
        return "ALTER TABLE \(quoteIdentifier(table)) ADD CONSTRAINT "
            + "\(quoteIdentifier(constraint.name)) CHECK (\(expression))"
    }

    func generateDropCheckConstraintSQL(table: String, constraintName: String) -> String? {
        guard SQLitePlugin.supportsCheckConstraintEditing, !constraintName.isEmpty else { return nil }
        return "ALTER TABLE \(quoteIdentifier(table)) DROP CONSTRAINT \(quoteIdentifier(constraintName))"
    }

    func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String? {
        SQLiteIndexCatalog.createStatement(for: index, table: table, quote: sqliteQuoteIdentifier)
    }

    func generateDropIndexSQL(table: String, indexName: String) -> String? {
        "DROP INDEX \(quoteIdentifier(indexName))"
    }

    private func formatDDL(_ ddl: String) -> String {
        guard ddl.uppercased().hasPrefix("CREATE TABLE") else {
            return ddl
        }

        var formatted = ddl

        if let range = formatted.range(of: "(") {
            let before = String(formatted[..<range.lowerBound])
            let after = String(formatted[range.upperBound...])
            formatted = before + "(\n  " + after.trimmingCharacters(in: .whitespaces)
        }

        var result = ""
        var depth = 0
        var i = 0
        let chars = Array(formatted)

        while i < chars.count {
            let char = chars[i]

            if char == "(" {
                depth += 1
                result.append(char)
            } else if char == ")" {
                depth -= 1
                result.append(char)
            } else if char == "," && depth == 1 {
                result.append(",\n  ")
                i += 1
                while i < chars.count && chars[i].isWhitespace {
                    i += 1
                }
                i -= 1
            } else {
                result.append(char)
            }

            i += 1
        }

        formatted = result

        if let range = formatted.range(of: ")", options: .backwards) {
            let before = String(formatted[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let after = String(formatted[range.lowerBound...])
            formatted = before + "\n" + after
        }

        return formatted.isEmpty ? ddl : formatted
    }
}

// MARK: - Errors

enum SQLitePluginError: Error {
    case connectionFailed(String)
    case notConnected
    case queryFailed(String)
    case unsupportedOperation
}

extension SQLitePluginError: PluginDriverError {
    var pluginErrorMessage: String {
        switch self {
        case .connectionFailed(let msg): return msg
        case .notConnected: return String(localized: "Not connected to database")
        case .queryFailed(let msg): return msg
        case .unsupportedOperation: return String(localized: "Operation not supported")
        }
    }
}
