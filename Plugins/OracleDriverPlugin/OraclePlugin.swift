//
//  OraclePlugin.swift
//  TablePro
//

import Foundation
import os
import TableProOracleCore
import TableProPluginKit

final class OraclePlugin: NSObject, TableProPlugin, DriverPlugin, PluginDiagnosticProvider {
    static let pluginName = "Oracle Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Oracle Database support via OracleNIO"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "Oracle"

    static let supportsRenameTable = true
    static let databaseDisplayName = "Oracle"
    static let iconName = "oracle-icon"
    static let defaultPort = 1_521
    static let additionalConnectionFields: [ConnectionField] = [
        ConnectionField(
            id: OracleConnectionOptions.AdditionalFieldKey.connectionType,
            label: "Connection Type",
            defaultValue: OracleConnectionOptions.IdentifierMode.service.rawValue,
            fieldType: .dropdown(options: [
                ConnectionField.DropdownOption(
                    value: OracleConnectionOptions.IdentifierMode.service.rawValue,
                    label: "Service Name"
                ),
                ConnectionField.DropdownOption(
                    value: OracleConnectionOptions.IdentifierMode.sid.rawValue,
                    label: "SID"
                )
            ])
        ),
        ConnectionField(
            id: OracleConnectionOptions.AdditionalFieldKey.serviceName,
            label: "Service Name",
            placeholder: "ORCL",
            visibleWhen: FieldVisibilityRule(
                fieldId: OracleConnectionOptions.AdditionalFieldKey.connectionType,
                values: [OracleConnectionOptions.IdentifierMode.service.rawValue]
            )
        ),
        ConnectionField(
            id: OracleConnectionOptions.AdditionalFieldKey.sid,
            label: "SID",
            placeholder: "XE",
            visibleWhen: FieldVisibilityRule(
                fieldId: OracleConnectionOptions.AdditionalFieldKey.connectionType,
                values: [OracleConnectionOptions.IdentifierMode.sid.rawValue]
            )
        ),
        ConnectionField(
            id: OracleConnectionOptions.AdditionalFieldKey.role,
            label: "Role",
            defaultValue: OracleConnectionOptions.Role.normal.rawValue,
            fieldType: .dropdown(options: [
                ConnectionField.DropdownOption(
                    value: OracleConnectionOptions.Role.normal.rawValue,
                    label: "Normal"
                ),
                ConnectionField.DropdownOption(
                    value: OracleConnectionOptions.Role.sysdba.rawValue,
                    label: "SYSDBA"
                ),
                ConnectionField.DropdownOption(
                    value: OracleConnectionOptions.Role.sysoper.rawValue,
                    label: "SYSOPER"
                )
            ])
        ),
        ConnectionField(
            id: OracleConnectionOptions.AdditionalFieldKey.networkEncryption,
            label: "Network Encryption",
            defaultValue: OracleConnectionOptions.NetworkEncryption.accepted.rawValue,
            fieldType: .dropdown(options: [
                ConnectionField.DropdownOption(
                    value: OracleConnectionOptions.NetworkEncryption.accepted.rawValue,
                    label: "Accepted"
                ),
                ConnectionField.DropdownOption(
                    value: OracleConnectionOptions.NetworkEncryption.rejected.rawValue,
                    label: "Rejected"
                ),
                ConnectionField.DropdownOption(
                    value: OracleConnectionOptions.NetworkEncryption.requested.rawValue,
                    label: "Requested"
                ),
                ConnectionField.DropdownOption(
                    value: OracleConnectionOptions.NetworkEncryption.required.rawValue,
                    label: "Required"
                )
            ])
        )
    ]

    // MARK: - UI/Capability Metadata

    static let isDownloadable = true
    static let supportsTriggers = true
    static let supportsRoutines = true
    static let supportsDatabaseTriggerBrowse = true
    static let supportsTriggerEditing = true
    static let pathFieldRole: PathFieldRole = .serviceName
    static let supportsForeignKeyDisable = false
    static let supportsDatabaseSwitching = false
    static let supportsSchemaSwitching = true
    static let defaultSchemaName = ""
    static let containerEntityName = "Schema"
    static let postConnectActions: [PostConnectAction] = [.selectSchemaFromLastSession]
    static let brandColorHex = "#C3160B"
    static let systemDatabaseNames: [String] = ["SYS", "SYSTEM", "OUTLN", "DBSNMP", "APPQOSSYS", "WMSYS", "XDB"]
    static let databaseGroupingStrategy: GroupingStrategy = .hierarchicalSchema
    static let columnTypesByCategory: [String: [String]] = [
        "Integer": ["NUMBER", "INTEGER", "INT", "SMALLINT"],
        "Float": ["FLOAT", "BINARY_FLOAT", "BINARY_DOUBLE", "DECIMAL", "NUMERIC", "REAL", "DOUBLE PRECISION"],
        "String": ["VARCHAR2", "NVARCHAR2", "CHAR", "NCHAR", "CLOB", "NCLOB", "LONG"],
        "Date": ["DATE", "TIMESTAMP", "TIMESTAMP WITH TIME ZONE", "TIMESTAMP WITH LOCAL TIME ZONE", "INTERVAL YEAR TO MONTH", "INTERVAL DAY TO SECOND"],
        "Binary": ["RAW", "LONG RAW", "BLOB", "BFILE"],
        "Boolean": [],
        "XML": ["XMLTYPE"],
        "Spatial": ["SDO_GEOMETRY"],
        "Other": ["ROWID", "UROWID"]
    ]

    static let sqlDialect: SQLDialectDescriptor? = SQLDialectDescriptor(
        identifierQuote: "\"",
        keywords: [
            "SELECT", "FROM", "WHERE", "JOIN", "INNER", "LEFT", "RIGHT", "OUTER", "CROSS", "FULL",
            "ON", "USING", "AND", "OR", "NOT", "IN", "LIKE", "BETWEEN", "AS",
            "ORDER", "BY", "GROUP", "HAVING", "FETCH", "FIRST", "ROWS", "ONLY", "OFFSET",
            "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "MERGE",
            "CREATE", "ALTER", "DROP", "TABLE", "INDEX", "VIEW", "DATABASE", "SCHEMA",
            "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "CONSTRAINT",
            "ADD", "MODIFY", "COLUMN", "RENAME",
            "NULL", "IS", "ASC", "DESC", "DISTINCT", "ALL", "ANY", "SOME",
            "SEQUENCE", "SYNONYM", "GRANT", "REVOKE", "TRIGGER", "PROCEDURE",
            "CASE", "WHEN", "THEN", "ELSE", "END", "COALESCE", "NULLIF", "DECODE",
            "UNION", "INTERSECT", "MINUS",
            "DECLARE", "BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT",
            "EXECUTE", "IMMEDIATE",
            "OVER", "PARTITION", "ROW_NUMBER", "RANK", "DENSE_RANK",
            "RETURNING", "CONNECT", "LEVEL", "START", "WITH", "PRIOR",
            "ROWNUM", "ROWID", "DUAL", "SYSDATE", "SYSTIMESTAMP"
        ],
        functions: [
            "COUNT", "SUM", "AVG", "MAX", "MIN", "LISTAGG",
            "CONCAT", "SUBSTR", "INSTR", "LENGTH", "LOWER", "UPPER",
            "TRIM", "LTRIM", "RTRIM", "REPLACE", "LPAD", "RPAD",
            "INITCAP", "TRANSLATE",
            "SYSDATE", "SYSTIMESTAMP", "CURRENT_DATE", "CURRENT_TIMESTAMP",
            "ADD_MONTHS", "MONTHS_BETWEEN", "LAST_DAY", "NEXT_DAY",
            "EXTRACT", "TO_DATE", "TO_CHAR", "TO_NUMBER", "TO_TIMESTAMP",
            "TRUNC", "ROUND",
            "CEIL", "FLOOR", "ABS", "POWER", "SQRT", "MOD", "SIGN",
            "NVL", "NVL2", "DECODE", "COALESCE", "NULLIF",
            "GREATEST", "LEAST", "CAST",
            "SYS_GUID", "DBMS_RANDOM.VALUE", "USER", "SYS_CONTEXT"
        ],
        dataTypes: [
            "NUMBER", "INTEGER", "SMALLINT", "FLOAT", "BINARY_FLOAT", "BINARY_DOUBLE",
            "CHAR", "VARCHAR2", "NCHAR", "NVARCHAR2", "CLOB", "NCLOB", "LONG",
            "BLOB", "RAW", "LONG RAW", "BFILE",
            "DATE", "TIMESTAMP", "TIMESTAMP WITH TIME ZONE", "TIMESTAMP WITH LOCAL TIME ZONE",
            "INTERVAL YEAR TO MONTH", "INTERVAL DAY TO SECOND",
            "BOOLEAN", "ROWID", "UROWID", "XMLTYPE", "SDO_GEOMETRY"
        ],
        tableOptions: [
            "TABLESPACE", "PCTFREE", "INITRANS"
        ],
        regexSyntax: .regexpLike,
        booleanLiteralStyle: .numeric,
        likeEscapeStyle: .explicit,
        paginationStyle: .offsetFetch,
        offsetFetchOrderBy: "ORDER BY 1",
        autoLimitStyle: .fetchFirst,
        caseSensitivityStyle: .caseFoldFunction
    )

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        OraclePluginDriver(config: config)
    }
}

final class OraclePluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let config: DriverConnectionConfig
    private var core: OracleCoreConnection?
    private var _currentSchema: String?
    private var _serverVersion: String?

    private static let logger = Logger(subsystem: "com.TablePro", category: "OraclePluginDriver")

    var currentSchema: String? { _currentSchema }
    var serverVersion: String? { _serverVersion }
    var supportsSchemas: Bool { true }
    var supportsTransactions: Bool { true }

    var capabilities: PluginCapabilities {
        [
            .transactions,
            .alterTableDDL,
            .multiSchema,
            .schemaCompare,
            .dataCompare,
        ]
    }

    init(config: DriverConnectionConfig) {
        self.config = config
    }

    // MARK: - View Templates

    func createViewTemplate() -> String? {
        "CREATE OR REPLACE VIEW view_name AS\nSELECT column1, column2\nFROM table_name\nWHERE condition;"
    }

    func editViewFallbackTemplate(viewName: String) -> String? {
        let quoted = quoteIdentifier(viewName)
        return "CREATE OR REPLACE VIEW \(quoted) AS\nSELECT * FROM table_name;"
    }

    // MARK: - Connection

    func connect() async throws {
        let connection = OracleCoreConnection(options: OracleConnectionOptions(
            host: config.host,
            port: config.port,
            user: config.username,
            password: config.password,
            database: config.database,
            identifierMode: OracleConnectionOptions.identifierMode(from: config.additionalFields),
            serviceName: config.additionalFields[OracleConnectionOptions.AdditionalFieldKey.serviceName] ?? "",
            sid: config.additionalFields[OracleConnectionOptions.AdditionalFieldKey.sid] ?? "",
            role: OracleConnectionOptions.role(from: config.additionalFields),
            tls: config.ssl.oracleTLSDescription,
            networkEncryption: OracleConnectionOptions.networkEncryption(from: config.additionalFields)
        ))
        do {
            try await connection.connect()
        } catch let error as OracleCoreError {
            throw error.asPluginError
        }
        self.core = connection

        do {
            try await connection.captureServerOutput()
        } catch {
            Self.logger.warning("DBMS_OUTPUT could not be enabled for this session: \(String(describing: error), privacy: .public)")
        }

        if let result = try? await connection.executeQuery(OracleSchemaQueries.currentSchema),
           let schema = result.rows.first?.first?.stringValue {
            _currentSchema = schema
        } else {
            _currentSchema = config.username.uppercased()
        }
        try ensureAlive(connection)

        if let result = try? await connection.executeQuery(OracleSchemaQueries.serverVersion),
           let versionStr = result.rows.first?.first?.stringValue {
            _serverVersion = String(versionStr.prefix(60))
        }
        try ensureAlive(connection)
    }

    /// A probe that only failed to answer is survivable, and both have a fallback. One that killed the
    /// connection is not: the core is left disconnected, so the next call silently redials with the full
    /// login budget while the caller's own, shorter deadline blames whatever step it happened to be on.
    /// Checked after each probe, because a redial inside the second one would mask the first's failure.
    private func ensureAlive(_ connection: OracleCoreConnection) throws {
        guard connection.isConnected else {
            core = nil
            throw OraclePluginError(core: .notConnected)
        }
    }

    func disconnect() {
        core?.disconnect()
        core = nil
    }

    func ping() async throws {
        guard let core else { throw OraclePluginError(core: .notConnected) }
        do {
            try await core.ping()
        } catch let error as OracleCoreError {
            throw error.asPluginError
        }
    }

    func applyQueryTimeout(_ seconds: Int) async throws {
        core?.applyQueryTimeout(seconds)
    }

    // MARK: - Transaction Management

    func beginTransaction() async throws {
        guard let core else { throw OraclePluginError(core: .notConnected) }
        core.beginTransaction()
    }

    func sessionTransactionState() async -> PluginSessionTransactionState {
        guard let core else { return .unknown }
        return core.holdsTransaction ? .inTransaction : .idle
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> PluginQueryResult {
        let startTime = Date()

        // Health monitor sends "SELECT 1" as a ping; Oracle requires FROM DUAL.
        let isBareSelectOne = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "select 1"
        var result = try await rawQuery(isBareSelectOne ? OracleSchemaQueries.ping : query)
        try await reportCompilationErrors(of: query)
        let executionTime = Date().timeIntervalSince(startTime)

        // OracleNIO may not populate column metadata for empty result sets.
        if result.columns.isEmpty, result.rows.isEmpty,
           let recovered = try? await emptyResultColumns(for: query) {
            result = recovered
        }
        if OraclePLSQLUnit.isAnonymousBlock(query) {
            result = OracleRawResult(columns: result.columns, rows: result.rows, affectedRows: 0, isTruncated: false)
        }

        return result.toPluginResult(executionTime: executionTime)
    }

    /// At most this many lines are read after one statement. A loop that prints more is reported as truncated
    /// rather than read into memory, and the rest of its buffer is discarded on the server.
    static let serverOutputLineLimit = 10_000

    func fetchServerOutput() async throws -> PluginServerOutput {
        guard let core else { return .none }
        do {
            let output = try await core.drainServerOutput(maxLines: Self.serverOutputLineLimit)
            return PluginServerOutput(lines: output.lines, isTruncated: output.isTruncated)
        } catch let error as OracleCoreError {
            throw error.asPluginError
        }
    }

    /// Turns a `CREATE` that stored an INVALID unit into the failure it is.
    ///
    /// Oracle accepts the statement and flags the compile failure only as a warning, which oracle-nio drops, so the
    /// unit's own errors are read back from `ALL_ERRORS`. A unit the header does not name, or one that compiled, adds
    /// nothing.
    func reportCompilationErrors(of query: String) async throws {
        guard let unit = OraclePLSQLUnit.definition(in: query) else { return }
        let errors = try await rawQuery(unit.errorsQuery).rows.compactMap(OracleCompilationError.init(row:))
        guard !errors.isEmpty else { return }
        throw OraclePluginError(core: .queryFailed(unit.compilationFailureMessage(errors: errors)))
    }

    internal func rawQuery(_ query: String) async throws -> OracleRawResult {
        guard let core else { throw OraclePluginError(core: .notConnected) }
        do {
            return try await core.executeQuery(query)
        } catch let error as OracleCoreError {
            throw error.asPluginError
        }
    }

    private func emptyResultColumns(for query: String) async throws -> OracleRawResult? {
        guard let table = Self.extractTableNameFromSelect(query) else { return nil }
        let sql = OracleSchemaQueries.columnNamesAndTypes(schema: effectiveSchema(nil), table: table)
        let columns = try await rawQuery(sql).rows.compactMap { row -> OracleColumnDescriptor? in
            guard let name = row.first?.stringValue else { return nil }
            let typeName = (row.count > 1 ? row[1].stringValue : nil)?.lowercased() ?? "varchar2"
            return OracleColumnDescriptor(name: name, typeName: typeName)
        }
        guard !columns.isEmpty else { return nil }
        return OracleRawResult(columns: columns, rows: [], affectedRows: 0, isTruncated: false)
    }

    // MARK: - Streaming

    func executeBoundedQuery(query: String, rowCap: Int) async throws -> PluginQueryResult? {
        let result = try await boundedQueryFromStream(query: query, rowCap: rowCap)
        try await reportCompilationErrors(of: query)
        return result
    }

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        guard let core else {
            return AsyncThrowingStream { $0.finish(throwing: OraclePluginError(core: .notConnected)) }
        }

        return PluginRowStream.make { continuation, abort in
            let streamTask = Task {
                /// The core read runs in its own unstructured task, which the outer one cannot
                /// cancel: a plain `Task {}` inherits context but is not a child. Cancelling it
                /// explicitly on abort is what stops oracle-nio, whose own loop already checks
                /// cancellation once it is reachable.
                let coreStream = AsyncThrowingStream<OracleStreamElement, Error> { coreContinuation in
                    let coreTask = Task {
                        do {
                            try await core.streamQuery(query, continuation: coreContinuation)
                        } catch {
                            coreContinuation.finish(throwing: error)
                        }
                    }
                    abort.onAbort { coreTask.cancel() }
                    coreContinuation.onTermination = { @Sendable _ in coreTask.cancel() }
                }
                do {
                    for try await element in coreStream {
                        switch element {
                        case .header(let columns):
                            continuation.yield(.header(PluginStreamHeader(
                                columns: columns.map(\.name),
                                columnTypeNames: columns.map(\.typeName)
                            )))
                        case .rows(let batch):
                            continuation.yield(.rows(batch.map { $0.map(\.asPluginCell) }))
                        }
                    }
                    continuation.finish()
                } catch let error as OracleCoreError {
                    continuation.finish(throwing: error.asPluginError)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            abort.onAbort { streamTask.cancel() }
        }
    }

    // MARK: - Schema Operations

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        let result = try await rawQuery(OracleSchemaQueries.tables(schema: effectiveSchema(schema)))
        return result.rows.compactMap(OracleSchemaQueries.parseTableRow).map { row in
            PluginTableInfo(
                name: row.name,
                type: row.isView ? "VIEW" : (row.isPartitioned ? "PARTITIONED TABLE" : "TABLE"),
                comment: nil,
                partitionCount: row.partitionCount
            )
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let result = try await rawQuery(
            OracleSchemaQueries.columns(schema: effectiveSchema(schema), table: table)
        )
        return result.rows.compactMap(OracleSchemaQueries.parseColumnRow).map {
            PluginColumnInfo(
                name: $0.name,
                dataType: $0.displayType,
                isNullable: $0.isNullable,
                isPrimaryKey: $0.isPrimaryKey,
                defaultValue: nil
            )
        }
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        let result = try await rawQuery(
            OracleSchemaQueries.indexes(schema: effectiveSchema(schema), table: table)
        )
        var indexMap: [String: (unique: Bool, primary: Bool, columns: [String])] = [:]
        for row in result.rows {
            guard let parsed = OracleSchemaQueries.parseIndexRow(row) else { continue }
            if indexMap[parsed.name] == nil {
                indexMap[parsed.name] = (unique: parsed.isUnique, primary: parsed.isPrimary, columns: [])
            }
            indexMap[parsed.name]?.columns.append(parsed.columnName)
        }
        return indexMap.map { name, info in
            PluginIndexInfo(
                name: name,
                columns: info.columns,
                isUnique: info.unique,
                isPrimary: info.primary,
                type: "BTREE"
            )
        }.sorted { $0.name < $1.name }
    }

    func fetchIndexDDL(table: String, schema: String?) async throws -> [String] {
        let owner = effectiveSchema(schema)
        let result = try await rawQuery(OracleIndexStatements.query(schema: owner, table: table))
        return OracleIndexStatements.render(
            rows: result.rows.map { row in row.map { $0.stringValue } },
            schema: owner,
            table: table,
            quote: quoteIdentifier)
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        let result = try await rawQuery(
            OracleSchemaQueries.foreignKeys(schema: effectiveSchema(schema), table: table)
        )
        return result.rows.compactMap(OracleSchemaQueries.parseForeignKeyRow).map {
            PluginForeignKeyInfo(
                name: $0.constraintName,
                column: $0.columnName,
                referencedTable: $0.referencedTable,
                referencedColumn: $0.referencedColumn,
                referencedSchema: $0.referencedSchema,
                onDelete: $0.deleteRule,
                onUpdate: "NO ACTION"
            )
        }
    }

    func fetchTriggers(table: String, schema: String?) async throws -> [PluginTriggerInfo] {
        try await triggerList(schema: effectiveSchema(schema), table: table)
    }

    var triggerEditUsesReplace: Bool { true }

    var replacesDefinitionsInPlace: Bool { true }

    func createTriggerTemplate(table: String, schema: String?) -> String? {
        let quotedTable = "\"\(table.replacingOccurrences(of: "\"", with: "\"\""))\""
        return """
        CREATE OR REPLACE TRIGGER \("\"TRIGGER_NAME\"")
        BEFORE INSERT ON \(quotedTable)
        FOR EACH ROW
        BEGIN
            -- :NEW.column := ...;
            NULL;
        END;
        """
    }

    func generateDropTriggerSQL(name: String, table: String, schema: String?) -> String? {
        OracleObjectQueries.dropTrigger(name: name, schema: schema, currentSchema: _currentSchema)
    }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        let sql = OracleSchemaQueries.allColumns(schema: effectiveSchema(schema))
        let result = try await execute(query: sql)
        var columnsByTable: [String: [PluginColumnInfo]] = [:]
        for row in result.rows {
            guard let tableName = row[safe: 0]?.asText,
                  let name = row[safe: 1]?.asText else { continue }
            let dataType = (row[safe: 2]?.asText)?.lowercased() ?? "varchar2"
            let dataLength = row[safe: 3]?.asText
            let precision = row[safe: 4]?.asText
            let scale = row[safe: 5]?.asText
            let isNullable = (row[safe: 6]?.asText) == "Y"
            let isPk = (row[safe: 7]?.asText) == "Y"

            let fullType = buildOracleFullType(dataType: dataType, dataLength: dataLength, precision: precision, scale: scale)

            let col = PluginColumnInfo(
                name: name,
                dataType: fullType,
                isNullable: isNullable,
                isPrimaryKey: isPk,
                defaultValue: nil
            )
            columnsByTable[tableName, default: []].append(col)
        }
        return columnsByTable
    }

    var providesBulkForeignKeyFetch: Bool { true }

    func fetchAllForeignKeys(schema: String?) async throws -> [String: [PluginForeignKeyInfo]] {
        let sql = OracleSchemaQueries.allForeignKeys(schema: effectiveSchema(schema))
        let result = try await execute(query: sql)
        var fksByTable: [String: [PluginForeignKeyInfo]] = [:]
        for row in result.rows {
            guard let tableName = row[safe: 0]?.asText,
                  let constraintName = row[safe: 1]?.asText,
                  let columnName = row[safe: 2]?.asText,
                  let refTable = row[safe: 3]?.asText,
                  let refColumn = row[safe: 4]?.asText else { continue }
            let deleteRule = (row[safe: 5]?.asText) ?? "NO ACTION"
            let fk = PluginForeignKeyInfo(
                name: constraintName,
                column: columnName,
                referencedTable: refTable,
                referencedColumn: refColumn,
                referencedSchema: row[safe: 6]?.asText,
                onDelete: deleteRule,
                onUpdate: "NO ACTION"
            )
            fksByTable[tableName, default: []].append(fk)
        }
        return fksByTable
    }

    func fetchAllDatabaseMetadata() async throws -> [PluginDatabaseMetadata] {
        let result = try await execute(query: OracleSchemaQueries.databaseSummaries)
        let sizesByOwner = await schemaSegmentSizes()
        return result.rows.compactMap { row -> PluginDatabaseMetadata? in
            guard let name = row[safe: 0]?.asText else { return nil }
            let tableCount = (row[safe: 1]?.asText).flatMap { Int($0) } ?? 0
            return PluginDatabaseMetadata(name: name, tableCount: tableCount, sizeBytes: sizesByOwner[name])
        }
    }

    /// The per-schema segment sizes, or an empty map when the reader lacks the DBA privilege the view needs. It is a
    /// separate best-effort read because a non-DBA cannot query `DBA_SEGMENTS` and joining it would fail the whole
    /// summary; `ALL_SEGMENTS` cannot stand in for it because Oracle has no such view.
    private func schemaSegmentSizes() async -> [String: Int64] {
        guard let result = try? await execute(query: OracleSchemaQueries.schemaSegmentSizes) else { return [:] }
        var sizes: [String: Int64] = [:]
        for row in result.rows {
            guard let owner = row[safe: 0]?.asText, let bytes = (row[safe: 1]?.asText).flatMap({ Int64($0) }) else {
                continue
            }
            sizes[owner] = bytes
        }
        return sizes
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")
        let escaped = effectiveSchemaEscaped(schema)

        // Do NOT use DBMS_METADATA.GET_DDL — if the object type is wrong
        // (view, materialized view, etc.), Oracle returns ORA-31603 which
        // corrupts OracleNIO's connection state machine. Build DDL manually.

        let cols = try await fetchColumns(table: table, schema: schema)
        var ddl = "CREATE TABLE \"\(escaped)\".\"\(escapedTable)\" (\n"
        let colDefs = cols.map { col -> String in
            var def = "    \"\(col.name)\" \(col.dataType.uppercased())"
            if !col.isNullable { def += " NOT NULL" }
            if let d = col.defaultValue, !d.isEmpty { def += " DEFAULT \(d)" }
            return def
        }
        ddl += colDefs.joined(separator: ",\n")
        ddl += "\n);"
        return ddl
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        // ALL_VIEWS.TEXT is LONG (crashes OracleNIO). TEXT_VC is VARCHAR2(4000), safe.
        // Do NOT use DBMS_METADATA.GET_DDL — wrong object type triggers ORA-31603
        // which corrupts OracleNIO's connection state machine.
        let sql = OracleSchemaQueries.viewDefinition(schema: effectiveSchema(schema), view: view)
        let result = try await execute(query: sql)
        guard let body = result.rows.first?.first?.asText,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OraclePluginError(core: .queryFailed(
                String(format: String(localized: "Oracle returned no definition for view '%@'."), view)))
        }
        /// `TEXT_VC` is the view's `SELECT` and nothing else, so it needs the header a dump replays.
        /// Written bare it made the restore run a query and create no view.
        return "CREATE OR REPLACE VIEW \(quoteIdentifier(effectiveSchema(schema))).\(quoteIdentifier(view)) AS\n\(body)"
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        let owner = effectiveSchema(schema)
        let result = try await execute(query: OracleSchemaQueries.tableMetadata(schema: owner, table: table))
        if let row = result.rows.first {
            let rowCount = (row[safe: 0]?.asText).flatMap { Int64($0) }
            let comment = row[safe: 1]?.asText
            let sizeBytes = await segmentSize(schema: owner, table: table) ?? 0
            return PluginTableMetadata(
                tableName: table,
                dataSize: sizeBytes,
                totalSize: sizeBytes,
                rowCount: rowCount,
                comment: comment
            )
        }

        // Fallback for views: ALL_TABLES returns no rows for views
        let viewResult = try await execute(query: OracleSchemaQueries.viewComment(schema: owner, view: table))
        if let row = viewResult.rows.first {
            let comment = row[safe: 0]?.asText
            return PluginTableMetadata(tableName: table, comment: comment)
        }

        return PluginTableMetadata(tableName: table)
    }

    /// The segment bytes of a table, or of the whole schema when `table` is nil, best-effort.
    ///
    /// The reader's own schema always answers through `USER_SEGMENTS`; another schema needs `DBA_SEGMENTS`, which a
    /// non-DBA cannot read, so a refusal returns nil rather than failing the metadata read. `ALL_SEGMENTS` is never
    /// used because Oracle has no such view (ORA-00942 even as `SYSTEM`).
    private func segmentSize(schema: String, table: String?) async -> Int64? {
        let ownedByCurrentSchema = schema.caseInsensitiveCompare(effectiveSchema(nil)) == .orderedSame
        let sql = OracleSchemaQueries.segmentSize(
            schema: schema, table: table, ownedByCurrentSchema: ownedByCurrentSchema
        )
        guard let result = try? await execute(query: sql) else { return nil }
        return (result.rows.first?[safe: 0]?.asText).flatMap { Int64($0) }
    }

    func fetchDatabases() async throws -> [String] {
        try await fetchUsers()
    }

    func fetchSchemas() async throws -> [String] {
        try await fetchUsers()
    }

    private func fetchUsers() async throws -> [String] {
        let result = try await rawQuery(OracleSchemaQueries.users)
        return result.rows.compactMap { $0.first?.stringValue }
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        do {
            let result = try await execute(query: OracleSchemaQueries.databaseTableCount(schema: database))
            if let row = result.rows.first {
                let tableCount = (row[safe: 0]?.asText).flatMap { Int($0) } ?? 0
                let sizeBytes = await segmentSize(schema: database, table: nil)
                return PluginDatabaseMetadata(
                    name: database,
                    tableCount: tableCount,
                    sizeBytes: sizeBytes
                )
            }
        } catch {
            Self.logger.debug("Failed to fetch database metadata: \(error.localizedDescription)")
        }
        return PluginDatabaseMetadata(name: database)
    }

    // MARK: - DML Statement Generation

    func generateStatements(
        table: String,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        generateStatements(
            table: table, schema: nil, columns: columns, primaryKeyColumns: primaryKeyColumns,
            changes: changes, insertedRowData: insertedRowData,
            deletedRowIndices: deletedRowIndices, insertedRowIndices: insertedRowIndices
        )
    }

    func generateStatements(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        let qualifiedTable = oracleQualifiedName(schema: schema, table: table)
        var statements: [(statement: String, parameters: [PluginCellValue])] = []

        for change in changes {
            switch change.type {
            case .insert:
                guard insertedRowIndices.contains(change.rowIndex) else { continue }
                if let values = insertedRowData[change.rowIndex] {
                    if let stmt = generateOracleInsert(qualifiedTable: qualifiedTable, columns: columns, values: values) {
                        statements.append(stmt)
                    }
                }
            case .update:
                if let stmt = generateOracleUpdate(qualifiedTable: qualifiedTable, columns: columns, change: change) {
                    statements.append(stmt)
                }
            case .delete:
                guard deletedRowIndices.contains(change.rowIndex) else { continue }
                if let stmt = generateOracleDelete(qualifiedTable: qualifiedTable, columns: columns, change: change) {
                    statements.append(stmt)
                }
            }
        }

        return statements.isEmpty ? nil : statements
    }

    private func escapeOracleIdentifier(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func generateOracleInsert(
        qualifiedTable: String,
        columns: [String],
        values: [PluginCellValue]
    ) -> (statement: String, parameters: [PluginCellValue])? {
        var insertColumns: [String] = []
        var valuesSQL: [String] = []
        var parameters: [PluginCellValue] = []

        for (index, value) in values.enumerated() {
            guard index < columns.count else { continue }
            insertColumns.append(escapeOracleIdentifier(columns[index]))
            if value.asText == "__DEFAULT__" {
                valuesSQL.append("DEFAULT")
            } else {
                valuesSQL.append("?")
                parameters.append(value)
            }
        }

        guard !insertColumns.isEmpty else { return nil }

        let columnList = insertColumns.joined(separator: ", ")
        let valueList = valuesSQL.joined(separator: ", ")
        let sql = "INSERT INTO \(qualifiedTable) (\(columnList)) VALUES (\(valueList))"
        return (statement: sql, parameters: parameters)
    }

    private func generateOracleUpdate(
        qualifiedTable: String,
        columns: [String],
        change: PluginRowChange
    ) -> (statement: String, parameters: [PluginCellValue])? {
        guard !change.cellChanges.isEmpty, let originalRow = change.originalRow else { return nil }

        var parameters: [PluginCellValue] = []

        let setClauses = change.cellChanges.map { cellChange -> String in
            let col = escapeOracleIdentifier(cellChange.columnName)
            parameters.append(cellChange.newValue)
            return "\(col) = ?"
        }.joined(separator: ", ")

        var conditions: [String] = []
        for (index, columnName) in columns.enumerated() {
            guard index < originalRow.count else { continue }
            let col = escapeOracleIdentifier(columnName)
            let value = originalRow[index]
            if value.isNull {
                conditions.append("\(col) IS NULL")
            } else {
                parameters.append(value)
                conditions.append("\(col) = ?")
            }
        }

        guard !conditions.isEmpty else { return nil }

        let whereClause = conditions.joined(separator: " AND ")
        let sql = "UPDATE \(qualifiedTable) SET \(setClauses) WHERE \(whereClause) AND ROWNUM = 1"
        return (statement: sql, parameters: parameters)
    }

    private func generateOracleDelete(
        qualifiedTable: String,
        columns: [String],
        change: PluginRowChange
    ) -> (statement: String, parameters: [PluginCellValue])? {
        guard let originalRow = change.originalRow else { return nil }

        var parameters: [PluginCellValue] = []
        var conditions: [String] = []

        for (index, columnName) in columns.enumerated() {
            guard index < originalRow.count else { continue }
            let col = escapeOracleIdentifier(columnName)
            let value = originalRow[index]
            if value.isNull {
                conditions.append("\(col) IS NULL")
            } else {
                parameters.append(value)
                conditions.append("\(col) = ?")
            }
        }

        guard !conditions.isEmpty else { return nil }

        let whereClause = conditions.joined(separator: " AND ")
        let sql = "DELETE FROM \(qualifiedTable) WHERE \(whereClause) AND ROWNUM = 1"
        return (statement: sql, parameters: parameters)
    }

    // MARK: - Create Table DDL

    func generateCreateTableSQL(definition: PluginCreateTableDefinition) -> String? {
        guard let statements = generateCreateTableStatements(definition: definition),
              let createTable = statements.first else { return nil }
        let indexStatements = statements.dropFirst()
        guard !indexStatements.isEmpty else { return createTable + ";" }
        return createTable + ";\n\n" + indexStatements.joined(separator: ";\n") + ";"
    }

    /// The table and each of its indexes as a statement of its own. Oracle runs one statement per call, and sent as
    /// one text the table and its indexes fail with ORA-03405 and create nothing.
    func generateCreateTableStatements(definition: PluginCreateTableDefinition) -> [String]? {
        guard !definition.columns.isEmpty else { return nil }

        let qualifiedTable = oracleQualifiedTable(definition.tableName)
        let pkColumns = definition.columns.filter { $0.isPrimaryKey }
        let inlinePK = pkColumns.count == 1
        var parts: [String] = definition.columns.map { oracleColumnDefinition($0, inlinePK: inlinePK) }

        if pkColumns.count > 1 {
            let pkCols = pkColumns.map { quoteIdentifier($0.name) }.joined(separator: ", ")
            parts.append("PRIMARY KEY (\(pkCols))")
        }

        for fk in definition.foreignKeys {
            parts.append(oracleForeignKeyConstraint(fk))
        }

        let createTable = "CREATE TABLE \(qualifiedTable) (\n  " +
            parts.joined(separator: ",\n  ") +
            "\n)"
        let indexStatements = definition.indexes.map { oracleIndexDefinition($0, qualifiedTable: qualifiedTable) }
        return [createTable] + indexStatements
    }

    // MARK: - Definition SQL (clipboard copy)

    func generateColumnDefinitionSQL(column: PluginColumnDefinition) -> String? {
        oracleColumnDefinition(column, inlinePK: false)
    }

    func generateIndexDefinitionSQL(index: PluginIndexDefinition, tableName: String?) -> String? {
        let qualifiedTable = tableName.map { oracleQualifiedTable($0) } ?? "\"table\""
        return oracleIndexDefinition(index, qualifiedTable: qualifiedTable)
    }

    func generateForeignKeyDefinitionSQL(fk: PluginForeignKeyDefinition) -> String? {
        oracleForeignKeyConstraint(fk)
    }

    // MARK: - ALTER TABLE DDL

    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        let qt = oracleQualifiedTable(table)
        let colDef = oracleColumnDefinition(column, inlinePK: false)
        return "ALTER TABLE \(qt) ADD (\(colDef))"
    }

    func generateModifyColumnSQL(table: String, oldColumn: PluginColumnDefinition, newColumn: PluginColumnDefinition) -> String? {
        let qt = oracleQualifiedTable(table)
        var stmts: [String] = []

        if oldColumn.name != newColumn.name {
            stmts.append("ALTER TABLE \(qt) RENAME COLUMN \(quoteIdentifier(oldColumn.name)) TO \(quoteIdentifier(newColumn.name))")
        }

        var modifyParts: [String] = []
        let colName = quoteIdentifier(newColumn.name)

        let typeChanged = oldColumn.dataType.uppercased() != newColumn.dataType.uppercased()
        let nullabilityChanged = oldColumn.isNullable != newColumn.isNullable
        let defaultChanged = oldColumn.defaultValue != newColumn.defaultValue

        if typeChanged || nullabilityChanged || defaultChanged {
            var def = "\(colName) \(newColumn.dataType.uppercased())"
            if let defaultValue = newColumn.defaultValue {
                def += " DEFAULT \(defaultValue)"
            } else if defaultChanged {
                def += " DEFAULT NULL"
            }
            if !newColumn.isNullable {
                def += " NOT NULL"
            } else if nullabilityChanged {
                def += " NULL"
            }
            modifyParts.append(def)
        }

        if !modifyParts.isEmpty {
            stmts.append("ALTER TABLE \(qt) MODIFY (\(modifyParts.joined(separator: ", ")))")
        }

        return stmts.isEmpty ? nil : stmts.joined(separator: ";\n")
    }

    func generateDropColumnSQL(table: String, columnName: String) -> String? {
        "ALTER TABLE \(oracleQualifiedTable(table)) DROP COLUMN \(quoteIdentifier(columnName))"
    }

    /// Oracle has no positional clause, but making a column invisible and visible again moves it to
    /// the end of the visible order, so any order is reachable by appending the right suffix.
    ///
    /// Measured against Oracle Free 23: the cycle works on the primary key, on an identity column
    /// and on a virtual column; the rows, the default, the NOT NULL, the comment, the identity
    /// sequence, the constraints, the indexes and the foreign keys pointing at the table all
    /// survive it, and no data is read or written. Needs 12.1, where invisible columns arrived; an
    /// older server rejects the statement and the error is reported as it is.
    ///
    /// The two halves of a cycle are separate statements because Oracle commits each DDL on its
    /// own, so a column is invisible for the width of one statement. Cycling one column at a time
    /// keeps that window as small as it can be.
    func generateColumnReorderPlan(
        table: String,
        schema: String?,
        columns: [PluginColumnDefinition],
        desiredOrder: [String]
    ) async throws -> PluginColumnReorderPlan? {
        let qt = oracleQualifiedTable(table)
        let currentOrder = try await fetchColumns(table: table, schema: schema).map(\.name)
        let cycled = PluginColumnReorderPlanner.appendCycle(from: currentOrder, to: desiredOrder)
        let statements = cycled.flatMap { column -> [String] in
            let quoted = quoteIdentifier(column)
            return [
                "ALTER TABLE \(qt) MODIFY (\(quoted) INVISIBLE)",
                "ALTER TABLE \(qt) MODIFY (\(quoted) VISIBLE)"
            ]
        }
        guard !statements.isEmpty else { return nil }

        /// Oracle commits each DDL statement on its own, so there is no transaction to roll back:
        /// a cycle whose `VISIBLE` half fails, on a dropped connection or a server error, leaves
        /// that column hidden for good. Every cycled column gets a compensating `VISIBLE` that the
        /// executor runs on any mid-plan failure, which is idempotent on a column that is already
        /// visible and puts back the one that is not.
        return PluginColumnReorderPlan(
            statements: statements,
            compensation: cycled.map { "ALTER TABLE \(qt) MODIFY (\(quoteIdentifier($0)) VISIBLE)" },
            cost: .metadataOnly
        )
    }

    func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String? {
        oracleIndexDefinition(index, qualifiedTable: oracleQualifiedTable(table))
    }

    func generateDropIndexSQL(table: String, indexName: String) -> String? {
        "DROP INDEX \(quoteIdentifier(indexName))"
    }

    func generateAddForeignKeySQL(table: String, fk: PluginForeignKeyDefinition) -> String? {
        "ALTER TABLE \(oracleQualifiedTable(table)) ADD \(oracleForeignKeyConstraint(fk))"
    }

    func generateDropForeignKeySQL(table: String, constraintName: String) -> String? {
        "ALTER TABLE \(oracleQualifiedTable(table)) DROP CONSTRAINT \(quoteIdentifier(constraintName))"
    }

    // MARK: - DDL Helpers

    private func oracleQualifiedTable(_ table: String) -> String {
        let schema = _currentSchema ?? config.username.uppercased()
        return "\(quoteIdentifier(schema)).\(quoteIdentifier(table))"
    }

    private func oracleColumnDefinition(_ col: PluginColumnDefinition, inlinePK: Bool) -> String {
        var def = "\(quoteIdentifier(col.name)) \(col.dataType.uppercased())"
        if let defaultValue = col.defaultValue {
            def += " DEFAULT \(defaultValue)"
        }
        if !col.isNullable {
            def += " NOT NULL"
        }
        if inlinePK && col.isPrimaryKey {
            def += " PRIMARY KEY"
        }
        return def
    }

    private func oracleIndexDefinition(_ index: PluginIndexDefinition, qualifiedTable: String) -> String {
        let cols = index.columns.map { quoteIdentifier($0) }.joined(separator: ", ")
        let unique = index.isUnique ? "UNIQUE " : ""
        return "CREATE \(unique)INDEX \(quoteIdentifier(index.name)) ON \(qualifiedTable) (\(cols))"
    }

    private func oracleForeignKeyConstraint(_ fk: PluginForeignKeyDefinition) -> String {
        let cols = fk.columns.map { quoteIdentifier($0) }.joined(separator: ", ")
        let refCols = fk.referencedColumns.map { quoteIdentifier($0) }.joined(separator: ", ")
        let refTable: String
        if let schema = fk.referencedSchema, !schema.isEmpty {
            refTable = "\(quoteIdentifier(schema)).\(quoteIdentifier(fk.referencedTable))"
        } else {
            refTable = quoteIdentifier(fk.referencedTable)
        }
        let constraint = fk.name.isEmpty ? "" : "CONSTRAINT \(quoteIdentifier(fk.name)) "
        var def = "\(constraint)FOREIGN KEY (\(cols)) REFERENCES \(refTable)"
        if !refCols.isEmpty {
            def += " (\(refCols))"
        }
        if fk.onDelete != "NO ACTION" {
            def += " ON DELETE \(fk.onDelete)"
        }
        return def
    }

    // MARK: - Schema Switching

    func switchSchema(to schema: String) async throws {
        _ = try await rawQuery(OracleSchemaQueries.setCurrentSchema(schema))
        _currentSchema = schema
        core?.noteSessionSchema(schema)
    }

    /// Oracle has no real database concept; "switch database" is a schema switch.
    /// Aliases to keep `coordinator.switchDatabase` working from tab restore paths
    /// without relying on a manager-side kludge.
    func switchDatabase(to database: String) async throws {
        try await switchSchema(to: database)
    }

    // MARK: - All Tables Metadata

    func allTablesMetadataSQL(schema: String?) -> String? {
        OracleSchemaQueries.allTablesMetadata(schema: schema ?? currentSchema ?? "SYSTEM")
    }

    // MARK: - Query Building

    func buildBrowseQuery(
        table: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        buildBrowseQuery(
            table: table, schema: nil, sortColumns: sortColumns,
            columns: columns, limit: limit, offset: offset
        )
    }

    func buildBrowseQuery(
        table: String,
        schema: String?,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        var query = "SELECT * FROM \(oracleQualifiedName(schema: schema, table: table))"
        let orderBy = PluginSQLFilter.buildOrderByClause(
            sortColumns: sortColumns, columns: columns, quoteIdentifier: oracleQuoteIdentifier
        ) ?? "ORDER BY 1"
        query += " \(orderBy) OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
        return query
    }

    func buildFilteredQuery(
        table: String,
        filters: [(column: String, op: String, value: String)],
        logicMode: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        buildFilteredQuery(
            table: table, schema: nil, filters: filters, logicMode: logicMode,
            sortColumns: sortColumns, columns: columns, limit: limit, offset: offset
        )
    }

    func buildFilteredQuery(
        table: String,
        schema: String?,
        filters: [(column: String, op: String, value: String)],
        logicMode: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        buildFilteredQuery(
            table: table, schema: schema, filters: filters, logicMode: logicMode,
            sortColumns: sortColumns, columns: columns, limit: limit, offset: offset, columnKinds: [:]
        )
    }

    func buildFilteredQuery(
        table: String,
        schema: String?,
        filters: [(column: String, op: String, value: String)],
        logicMode: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int,
        columnKinds: [String: PluginColumnKind]
    ) -> String? {
        buildFilteredQuery(
            table: table, schema: schema,
            queryFilters: filters.map { PluginQueryFilter(column: $0.column, op: $0.op, value: $0.value) },
            logicMode: logicMode, sortColumns: sortColumns, columns: columns,
            limit: limit, offset: offset, columnKinds: columnKinds
        )
    }

    func buildFilteredQuery(
        table: String,
        schema: String?,
        queryFilters: [PluginQueryFilter],
        logicMode: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int,
        columnKinds: [String: PluginColumnKind]
    ) -> String? {
        var query = "SELECT * FROM \(oracleQualifiedName(schema: schema, table: table))"
        let whereClause = PluginSQLFilter.buildWhereClause(
            filters: queryFilters,
            logicMode: logicMode,
            columnKinds: columnKinds,
            caseSensitivityStyle: .caseFoldFunction,
            quoteIdentifier: oracleQuoteIdentifier,
            escapeTypedValue: oracleEscapeValue,
            regexCondition: { quoted, value, ignoresCase in
                let pattern = value.replacingOccurrences(of: "'", with: "''")
                guard ignoresCase else { return "REGEXP_LIKE(\(quoted), '\(pattern)')" }
                return "REGEXP_LIKE(\(quoted), '\(pattern)', 'i')"
            }
        )
        if !whereClause.isEmpty {
            query += " WHERE \(whereClause)"
        }
        let orderBy = PluginSQLFilter.buildOrderByClause(
            sortColumns: sortColumns, columns: columns, quoteIdentifier: oracleQuoteIdentifier
        ) ?? "ORDER BY 1"
        query += " \(orderBy) OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
        return query
    }

    // MARK: - Query Building Helpers

    private func oracleQualifiedName(schema: String?, table: String) -> String {
        guard let schema, !schema.isEmpty else {
            return oracleQuoteIdentifier(table)
        }
        return "\(oracleQuoteIdentifier(schema)).\(oracleQuoteIdentifier(table))"
    }

    private func oracleQuoteIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func oracleEscapeValue(_ value: String, kind: PluginColumnKind?) -> String {
        PluginSQLLiteral.escapedLiteral(
            value,
            kind: kind,
            trueLiteral: nil,
            falseLiteral: nil,
            quote: { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }
        )
    }

    // MARK: - Private Helpers

    private func buildOracleFullType(
        dataType: String,
        dataLength: String?,
        precision: String?,
        scale: String?
    ) -> String {
        OracleSchemaQueries.fullType(
            dataType: dataType,
            dataLength: dataLength,
            precision: precision,
            scale: scale
        )
    }

    func effectiveSchema(_ schema: String?) -> String {
        schema ?? _currentSchema ?? config.username.uppercased()
    }

    private func effectiveSchemaEscaped(_ schema: String?) -> String {
        OracleSchemaQueries.escapeLiteral(effectiveSchema(schema))
    }

    private static let fromTableRegex = try? NSRegularExpression(
        pattern: #"FROM\s+(?:"([^"]+)"|(\w+))"#,
        options: .caseInsensitive
    )

    private static func extractTableNameFromSelect(_ sql: String) -> String? {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: "^SELECT\\b", options: [.regularExpression, .caseInsensitive]) != nil else {
            return nil
        }
        let ns = trimmed as NSString
        guard let match = fromTableRegex?.firstMatch(
            in: trimmed,
            range: NSRange(location: 0, length: ns.length)
        ), match.numberOfRanges >= 3 else {
            return nil
        }
        let quotedRange = match.range(at: 1)
        if quotedRange.location != NSNotFound {
            return ns.substring(with: quotedRange)
        }
        let unquotedRange = match.range(at: 2)
        if unquotedRange.location != NSNotFound {
            return ns.substring(with: unquotedRange)
        }
        return nil
    }
}
