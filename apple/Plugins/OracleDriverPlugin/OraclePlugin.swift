//
//  OraclePlugin.swift
//  TablePro
//

import Foundation
import os
import TableProLogRedaction
import TableProOracleCore
import TableProPluginKit
import TableProSQLVocabulary

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
    static let sslModesThroughTunnel: [SSLMode] = SSLMode.allCases
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
    static let columnTypesByCategory: [String: [String]] = OracleTypeCatalog.columnTypesByCategory
    static let explainVariants: [ExplainVariant] = [
        .driverPlan(
            id: OracleExplainPlan.estimatedVariantId,
            label: String(localized: "Estimated Plan"),
            format: .oraclePlanRows,
            runsStatement: false
        ),
        .driverPlan(
            id: OracleExplainPlan.actualVariantId,
            label: String(localized: "Actual Plan"),
            format: .oraclePlanRows,
            runsStatement: true
        )
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
        functions: SQLEngineVocabulary.oracle.functions,
        dataTypes: SQLEngineVocabulary.oracle.dataTypes,
        tableOptions: SQLEngineVocabulary.oracle.tableOptions,
        regexSyntax: .regexpLike,
        booleanLiteralStyle: .numeric,
        likeEscapeStyle: .explicit,
        paginationStyle: .offsetFetch,
        offsetFetchOrderBy: "",
        autoLimitStyle: .fetchFirst,
        caseSensitivityStyle: .caseFoldFunction,
        operators: SQLEngineVocabulary.oracle.operators.compactMap(SQLOperatorDescriptor.init(vocabulary:)),
        textCastTypeName: nil,
        functionNamesAreCaseInsensitive: SQLEngineVocabulary.oracle.functionNamesAreCaseInsensitive,
        typeNamesAreCaseInsensitive: true
    )

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        OraclePluginDriver(config: config)
    }
}

private extension SQLOperatorDescriptor {
    init?(vocabulary entry: SQLEngineVocabulary.Operator) {
        guard let category = Category(rawValue: entry.category),
              let placement = Placement(rawValue: entry.placement) else { return nil }
        self.init(
            symbol: entry.symbol,
            summary: entry.summary,
            category: category,
            placement: placement,
            appliesToTypes: entry.appliesToTypes
        )
    }
}

final class OraclePluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    let config: DriverConnectionConfig
    private(set) var core: OracleCoreConnection?
    // Read by statement generation on any thread while a connect or a schema switch writes it.
    private let sessionSchema = OSAllocatedUnfairLock<String?>(initialState: nil)
    private var _serverVersion: String?
    let principalState = OSAllocatedUnfairLock(initialState: OraclePrincipalState())
    let debugState = OSAllocatedUnfairLock(initialState: OracleDebugState())

    private static let logger = Logger(subsystem: "com.TablePro", category: "OraclePluginDriver")

    var currentSchema: String? { sessionSchema.withLock { $0 } }
    var serverVersion: String? { _serverVersion }
    var connectionWarning: String? { core?.loginWarning }
    var supportsSchemas: Bool { true }
    var supportsTransactions: Bool { true }

    var capabilities: PluginCapabilities {
        [
            .transactions,
            .alterTableDDL,
            .multiSchema,
            .schemaCompare,
            .dataCompare,
            .cellExpressions,
            .uuidCellText,
            .userManagement,
            .columnDefaultMarks,
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
        let options = OracleConnectionOptions(
            host: config.host,
            port: config.port,
            user: config.username,
            password: config.password,
            database: config.database,
            identifierMode: OracleConnectionOptions.identifierMode(from: config.additionalFields),
            serviceName: config.additionalFields[OracleConnectionOptions.AdditionalFieldKey.serviceName] ?? "",
            sid: config.additionalFields[OracleConnectionOptions.AdditionalFieldKey.sid] ?? "",
            role: OracleConnectionOptions.role(from: config.additionalFields),
            tls: config.ssl.oracleTLSDescription(serverName: config.tunneledServerName),
            networkEncryption: OracleConnectionOptions.networkEncryption(from: config.additionalFields),
            loginTimeoutSeconds: OracleConnectionOptions.loginTimeoutSeconds(from: config.additionalFields)
        )
        let deadline = OracleConnectDeadline(seconds: options.loginTimeoutSeconds)
        let connection = OracleCoreConnection(options: options)
        do {
            try await connection.connect()
            self.core = connection

            do {
                try await connection.withConnectDeadline(deadline) {
                    try await connection.captureServerOutput()
                }
            } catch {
                try continueConnecting(afterOptionalProbeFailure: error, on: connection)
                Self.logger.warning("DBMS_OUTPUT could not be enabled for this session: \(LogRedaction.publicDescription(of: error), privacy: .public) \(String(describing: error), privacy: .private)")
            }

            if let result = try await optionalConnectQuery(
                OracleSchemaQueries.currentSchema,
                on: connection,
                deadline: deadline
            ), let schema = result.rows.first?.first?.stringValue {
                sessionSchema.withLock { $0 = schema }
            } else {
                sessionSchema.withLock { $0 = config.username.uppercased() }
            }

            if let result = try await optionalConnectQuery(
                OracleSchemaQueries.serverVersion,
                on: connection,
                deadline: deadline
            ), let versionStr = result.rows.first?.first?.stringValue {
                _serverVersion = String(versionStr.prefix(60))
            }
            try connection.finishConnecting(before: deadline)
        } catch let error as OracleCoreError {
            if !connection.isConnected {
                self.core = nil
            }
            throw error.asPluginError
        } catch is CancellationError {
            connection.disconnect(reason: .connectCancelled)
            self.core = nil
            throw CancellationError()
        }
    }

    private func optionalConnectQuery(
        _ query: String,
        on connection: OracleCoreConnection,
        deadline: OracleConnectDeadline
    ) async throws -> OracleRawResult? {
        do {
            return try await connection.withConnectDeadline(deadline) {
                try await connection.executeQuery(query)
            }
        } catch {
            try continueConnecting(afterOptionalProbeFailure: error, on: connection)
            return nil
        }
    }

    private func continueConnecting(
        afterOptionalProbeFailure error: Error,
        on connection: OracleCoreConnection
    ) throws {
        if let coreError = error as? OracleCoreError, coreError == .connectTimedOut {
            throw coreError
        }
        if error is CancellationError {
            throw error
        }
        try ensureAlive(connection)
    }

    // A probe that killed the connection leaves the core disconnected, and the next call would redial with the full
    // login budget under the caller's shorter deadline. Checked after each probe, so a redial cannot mask its failure.
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
        let result = try await rawQuery(isBareSelectOne ? OracleSchemaQueries.ping : query)
        try await reportCompilationErrors(of: query)
        return pluginResult(of: query, result, executionTime: Date().timeIntervalSince(startTime))
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        try await executeParameterized(query: query, parameters: parameters, context: PluginStatementContext())
    }

    // Values a literal can carry stay literals; only bytes and text over the literal limit are bound. The context
    // says the type of each value's column, or the kind the user gave it (`OracleBindPlaceholders`).
    func executeParameterized(
        query: String,
        parameters: [PluginCellValue],
        context: PluginStatementContext
    ) async throws -> PluginQueryResult {
        guard !parameters.isEmpty else { return try await execute(query: query) }
        let statement = try OracleBindPlaceholders.substituting(
            query,
            parameters: parameters,
            kinds: context.parameterKinds,
            typeNames: context.parameterTypeNames,
            writesBooleans: core?.serverRelease?.hasBooleanType ?? false
        )
        guard !statement.binds.isEmpty else { return try await execute(query: statement.sql) }
        guard let core else { throw OraclePluginError(core: .notConnected) }
        let startTime = Date()
        let result: OracleRawResult
        do {
            result = try await core.executeQuery(statement.sql, binds: statement.binds.map(\.oracleBindValue))
        } catch let error as OracleCoreError {
            throw error.asPluginError
        }
        try await reportCompilationErrors(of: query)
        return pluginResult(of: query, result, executionTime: Date().timeIntervalSince(startTime))
    }

    func executeUserQuery(query: String, rowCap: Int?, parameters: [PluginCellValue]?) async throws -> PluginQueryResult {
        try await executeUserQuery(query: query, rowCap: rowCap, parameters: parameters, context: PluginStatementContext())
    }

    // Overridden so the kinds the user gave the parameters reach the binder; the PluginKit default drops the context.
    // A capped result keeps its column hints, so a DATE column still reads with its time.
    func executeUserQuery(
        query: String,
        rowCap: Int?,
        parameters: [PluginCellValue]?,
        context: PluginStatementContext
    ) async throws -> PluginQueryResult {
        let raw: PluginQueryResult
        if let parameters {
            raw = try await executeParameterized(query: query, parameters: parameters, context: context)
        } else {
            raw = try await execute(query: query, context: context)
        }
        guard let cap = rowCap, cap > 0, raw.rows.count > cap else { return raw }
        return PluginQueryResult(
            columns: raw.columns,
            columnTypeNames: raw.columnTypeNames,
            rows: Array(raw.rows.prefix(cap)),
            rowsAffected: raw.rowsAffected,
            timing: raw.timing,
            isTruncated: true,
            statusMessage: raw.statusMessage,
            columnMeta: raw.columnMeta
        )
    }

    // An anonymous block reports no row count of its own; what oracle-nio counted belongs to the statements inside it.
    private func pluginResult(
        of query: String,
        _ result: OracleRawResult,
        executionTime: TimeInterval
    ) -> PluginQueryResult {
        guard OraclePLSQLUnit.isAnonymousBlock(query) else { return result.toPluginResult(executionTime: executionTime) }
        return OracleRawResult(columns: result.columns, rows: result.rows, affectedRows: 0, isTruncated: false)
            .toPluginResult(executionTime: executionTime)
    }

    // Lines read after one statement. More is reported as truncated, and the rest is discarded on the server.
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

    // Oracle stores an INVALID unit with only a warning, which oracle-nio drops, so its errors are read from
    // `ALL_ERRORS`. A unit the header does not name, or one that compiled, adds nothing.
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

    // MARK: - Streaming

    // The stream header has no field for classification hints, so they are added to the collected result.
    func executeBoundedQuery(query: String, rowCap: Int) async throws -> PluginQueryResult? {
        // The collector needs one row past the cap to tell a full result from a truncated one.
        let cap = max(rowCap, 1)
        let result = try await PluginBoundedStream.collect(
            rowStream(query: query, rowBudget: cap < Int.max ? cap + 1 : nil),
            rowCap: cap,
            startedAt: Date()
        )
        try await reportCompilationErrors(of: query)
        return result.withOracleClassificationHints()
    }

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        rowStream(query: query, rowBudget: nil)
    }

    private func rowStream(query: String, rowBudget: Int?) -> AsyncThrowingStream<PluginStreamElement, Error> {
        guard let core else {
            return AsyncThrowingStream { $0.finish(throwing: OraclePluginError(core: .notConnected)) }
        }
        let batching = OracleRowBatcher(rowsPerBatch: OracleRowBatcher.batchRows, rowBudget: rowBudget)

        return PluginRowStream.makeBounded { continuation, abort in
            // A plain `Task {}` is not a child of this one, so only the explicit cancel on abort stops oracle-nio.
            let streamTask = Task {
                do {
                    try await core.streamQuery(query, batching: batching, onElement: { element in
                        switch element {
                        case .header(let columns):
                            continuation.yield(.header(PluginStreamHeader(
                                columns: columns.map(\.name),
                                columnTypeNames: columns.map(\.typeName)
                            )))
                        case .rows(let batch):
                            _ = await PluginRowStream.deliver(.rows(batch.map { $0.map(\.asPluginCell) }), to: continuation)
                        case .affectedRows:
                            // The plugin stream carries rows only. The app sends writes and DDL through
                            // `execute`, which reports the count, and bounds only reads through this stream.
                            break
                        }
                    })
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
        let owner = effectiveSchema(schema)
        let result = try await rawQuery(OracleSchemaQueries.tables(schema: owner))
        let rows = result.rows.compactMap(OracleSchemaQueries.parseTableRow)
        return await withPartitionCounts(rows, defaultOwner: owner).map(Self.tableInfo)
    }

    func fetchTables(inSchemas schemas: [String]) async throws -> [PluginTableInfo]? {
        var rows: [OracleTableRow] = []
        for query in OracleSchemaQueries.tables(inSchemas: schemas) {
            let result = try await rawQuery(query)
            rows += result.rows.compactMap(OracleSchemaQueries.parseTableRow)
        }
        return await withPartitionCounts(rows, defaultOwner: nil).map(Self.tableInfo)
    }

    // The count only labels a row, so a failed read leaves the listing without counts rather than failing it.
    private func withPartitionCounts(_ rows: [OracleTableRow], defaultOwner: String?) async -> [OracleTableRow] {
        let owners = OracleSchemaQueries.ownersWithPartitionedTables(in: rows, defaultOwner: defaultOwner)
        guard !owners.isEmpty else { return rows }
        var countRows: [[OracleRawCell]] = []
        do {
            for query in OracleSchemaQueries.partitionCounts(owners: owners) {
                countRows += try await rawQuery(query).rows
            }
        } catch {
            Self.logger.warning("Partition counts could not be read: \(LogRedaction.publicDescription(of: error), privacy: .public)")
            return rows
        }
        return OracleSchemaQueries.applyingPartitionCounts(countRows, to: rows, defaultOwner: defaultOwner)
    }

    private static func tableInfo(_ row: OracleTableRow) -> PluginTableInfo {
        PluginTableInfo(
            name: row.name,
            type: row.isView ? "VIEW" : (row.isPartitioned ? "PARTITIONED TABLE" : "TABLE"),
            schema: row.schema,
            comment: nil,
            partitionCount: row.partitionCount
        )
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        try await exportCatalog.fetchColumns(table: table, schema: schema)
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
        try await exportCatalog.fetchIndexDDL(table: table, schema: schema)
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        try await exportCatalog.fetchForeignKeys(table: table, schema: schema)
    }

    func fetchTriggers(table: String, schema: String?) async throws -> [PluginTriggerInfo] {
        try await exportCatalog.fetchTriggers(table: table, schema: schema)
    }

    var triggerEditUsesReplace: Bool { true }

    var replacesDefinitionsInPlace: Bool { true }

    func createTriggerTemplate(table: String, schema: String?) -> String? {
        let quotedTable = OracleObjectQueries.quoteIdentifier(table)
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
        OracleExportCatalog.dropTriggerStatement(
            name: name, schema: schema, currentSchema: currentSchema, release: core?.serverRelease
        )
    }

    func generateDropRoutineSQL(name: String, signature: String?, schema: String?, isFunction: Bool) -> String? {
        OracleExportCatalog.dropRoutineStatement(
            name: name, schema: schema, currentSchema: currentSchema, isFunction: isFunction
        )
    }

    func generateDropRelationSQL(name: String, kind: PluginExportObjectKind, schema: String?) -> String? {
        OracleExportCatalog.dropRelationStatement(
            kind: kind, name: name, schema: schema, currentSchema: currentSchema, release: core?.serverRelease
        )
    }

    var fetchesAllColumnsInOneRequest: Bool { true }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        try await exportCatalog.fetchAllColumns(schema: schema)
    }

    func fetchAllColumnsForExport(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        try await exportCatalog.fetchAllColumns(schema: schema, keepsSpellingsApart: true)
    }

    var providesBulkForeignKeyFetch: Bool { true }

    func fetchAllForeignKeys(schema: String?) async throws -> [String: [PluginForeignKeyInfo]] {
        try await exportCatalog.fetchAllForeignKeys(schema: schema)
    }

    func fetchAllForeignKeysForExport(schema: String?) async throws -> [String: [PluginForeignKeyInfo]] {
        try await exportCatalog.fetchAllForeignKeys(schema: schema, keepsSpellingsApart: true)
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

    // A separate best-effort read: a non-DBA cannot query `DBA_SEGMENTS`, joining it would fail the whole summary, and
    // Oracle has no `ALL_SEGMENTS`. Empty without the privilege.
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
        try await exportCatalog.fetchTableDDL(table: table, schema: schema)
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        try await exportCatalog.fetchViewDefinition(view: view, schema: schema)
    }

    // NUM_ROWS is the last statistics gather, and NULL on a table that never had one.
    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        let owner = effectiveSchema(schema)
        let result = try await execute(query: OracleSchemaQueries.tableMetadata(schema: owner, table: table))
        return (result.rows.first?[safe: 0]?.asText).flatMap { Int($0) }
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

    // The reader's own schema answers through `USER_SEGMENTS`; another needs `DBA_SEGMENTS`, so a non-DBA gets nil.
    // Oracle has no `ALL_SEGMENTS` (ORA-00942 even as `SYSTEM`).
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
        let writes = (try? rowWriter(table: table, schema: schema, columns: columns, primaryKeyColumns: primaryKeyColumns)
            .rowWrites(
                for: changes, insertedRowData: insertedRowData,
                deletedRowIndices: deletedRowIndices, insertedRowIndices: insertedRowIndices
            )) ?? []
        return writes.isEmpty ? nil : writes.map { (statement: $0.statement, parameters: $0.parameters) }
    }

    func generateRowWrites(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) throws -> [PluginRowWrite]? {
        try generateRowWrites(
            table: table, schema: schema, columns: columns, primaryKeyColumns: primaryKeyColumns,
            changes: changes, insertedRowData: insertedRowData,
            deletedRowIndices: deletedRowIndices, insertedRowIndices: insertedRowIndices,
            context: PluginRowWriteContext()
        )
    }

    // Nothing to write is nil, never an empty list: a non-nil answer to an empty update claims the restore of deleted
    // rows, and this driver has no identity-preserving insert to restore them with.
    func generateRowWrites(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>,
        context: PluginRowWriteContext
    ) throws -> [PluginRowWrite]? {
        var writer = rowWriter(table: table, schema: schema, columns: columns, primaryKeyColumns: primaryKeyColumns)
        writer.context = context
        let writes = try writer.rowWrites(
            for: changes, insertedRowData: insertedRowData,
            deletedRowIndices: deletedRowIndices, insertedRowIndices: insertedRowIndices
        )
        return writes.isEmpty ? nil : writes
    }

    private func rowWriter(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String]
    ) -> OracleRowWriter {
        OracleRowWriter(
            qualifiedTable: OracleBrowseSQL.qualifiedName(schema: schema, table: table),
            columns: columns,
            primaryKeyColumns: primaryKeyColumns
        )
    }

    // MARK: - Create Table DDL

    // Oracle runs one statement per call: sent as one text, the table and its indexes fail with ORA-03405.
    func generateCreateTableStatements(definition: PluginCreateTableDefinition, schema: String?) -> [String]? {
        OracleCreateTableSQL.statements(
            definition: definition, schema: effectiveSchema(schema), supportsIdentity: supportsIdentityColumns
        )
    }

    func objectCommentStatement(name: String, objectType: String, schema: String?, comment: String?) -> String? {
        let qualifiedName = OracleObjectQueries.quoteIdentifier(effectiveSchema(schema)) + "."
            + OracleObjectQueries.quoteIdentifier(name)
        return OracleObjectQueries.commentStatement(qualifiedName: qualifiedName, objectType: objectType, comment: comment)
    }

    func schemaOperationRefusal(_ operation: PluginSchemaOperation) -> String? {
        guard case .addColumn(let column) = operation, column.autoIncrement else { return nil }
        if let release = core?.serverRelease, !release.hasIdentityColumns {
            return String(localized: "Oracle 11g has no identity columns, so a column cannot be auto-increment.")
        }
        guard let defaultValue = column.defaultValue,
              !defaultValue.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return String(localized: "An auto-increment column takes its values from a sequence, so it cannot also have a default.")
    }

    // MARK: - Definition SQL (clipboard copy)

    func generateColumnDefinitionSQL(column: PluginColumnDefinition) -> String? {
        oracleColumnDefinition(column, inlinePK: false)
    }

    func generateIndexDefinitionSQL(index: PluginIndexDefinition, tableName: String?) -> String? {
        let qualifiedTable = tableName.map { oracleQualifiedTable($0, schema: nil) } ?? "\"table\""
        return oracleIndexDefinition(index, qualifiedTable: qualifiedTable)
    }

    func generateForeignKeyDefinitionSQL(fk: PluginForeignKeyDefinition) -> String? {
        oracleForeignKeyConstraint(fk)
    }

    // MARK: - ALTER TABLE DDL

    func generateAddColumnSQL(table: String, schema: String?, column: PluginColumnDefinition) -> String? {
        let qt = oracleQualifiedTable(table, schema: schema)
        let colDef = oracleColumnDefinition(column, inlinePK: false)
        return "ALTER TABLE \(qt) ADD (\(colDef))"
    }

    func generateModifyColumnSQL(
        table: String,
        schema: String?,
        oldColumn: PluginColumnDefinition,
        newColumn: PluginColumnDefinition
    ) -> String? {
        OracleColumnStatements.modify(
            qualifiedTable: oracleQualifiedTable(table, schema: schema),
            oldColumn: oldColumn,
            newColumn: newColumn,
            quote: quoteIdentifier
        )
    }

    func generateDropColumnSQL(table: String, schema: String?, columnName: String) -> String? {
        "ALTER TABLE \(oracleQualifiedTable(table, schema: schema)) DROP COLUMN \(quoteIdentifier(columnName))"
    }

    // Making a column invisible and visible again moves it to the end, so any order is reachable. Measured on Oracle
    // Free 23: works on a primary key, identity and virtual column, keeps rows, defaults, NOT NULL, comments, identity
    // sequences, constraints, indexes and incoming foreign keys, and reads no data. Needs 12.1. One column at a time,
    // since Oracle commits each DDL on its own and the column is invisible between the two statements.
    func generateColumnReorderPlan(
        table: String,
        schema: String?,
        columns: [PluginColumnDefinition],
        desiredOrder: [String]
    ) async throws -> PluginColumnReorderPlan? {
        let qt = oracleQualifiedTable(table, schema: schema)
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

        // No transaction to roll back: a failed `VISIBLE` half leaves the column hidden, so every cycled column gets a
        // compensating `VISIBLE`, idempotent on one already visible, that the executor runs on a mid-plan failure.
        return PluginColumnReorderPlan(
            statements: statements,
            compensation: cycled.map { "ALTER TABLE \(qt) MODIFY (\(quoteIdentifier($0)) VISIBLE)" },
            cost: .metadataOnly
        )
    }

    func generateAddIndexSQL(table: String, schema: String?, index: PluginIndexDefinition) -> String? {
        oracleIndexDefinition(index, qualifiedTable: oracleQualifiedTable(table, schema: schema))
    }

    func generateDropIndexSQL(table: String, schema: String?, indexName: String) -> String? {
        "DROP INDEX \(quoteIdentifier(effectiveSchema(schema))).\(quoteIdentifier(indexName))"
    }

    func generateAddForeignKeySQL(table: String, schema: String?, fk: PluginForeignKeyDefinition) -> String? {
        "ALTER TABLE \(oracleQualifiedTable(table, schema: schema)) ADD \(oracleForeignKeyConstraint(fk))"
    }

    func generateDropForeignKeySQL(table: String, schema: String?, constraintName: String) -> String? {
        "ALTER TABLE \(oracleQualifiedTable(table, schema: schema)) DROP CONSTRAINT \(quoteIdentifier(constraintName))"
    }

    // MARK: - DDL Helpers

    // An unknown release writes the identity: `schemaOperationRefusal` stops auto-increment on a known 11g.
    private var supportsIdentityColumns: Bool {
        core?.serverRelease?.hasIdentityColumns ?? true
    }

    private func oracleQualifiedTable(_ table: String, schema: String?) -> String {
        OracleCreateTableSQL.qualifiedTable(table, schema: effectiveSchema(schema))
    }

    private func oracleColumnDefinition(_ col: PluginColumnDefinition, inlinePK: Bool) -> String {
        OracleCreateTableSQL.columnDefinition(col, inlinePrimaryKey: inlinePK, supportsIdentity: supportsIdentityColumns)
    }

    private func oracleIndexDefinition(_ index: PluginIndexDefinition, qualifiedTable: String) -> String {
        OracleCreateTableSQL.indexDefinition(index, qualifiedTable: qualifiedTable)
    }

    private func oracleForeignKeyConstraint(_ fk: PluginForeignKeyDefinition) -> String {
        OracleCreateTableSQL.foreignKeyConstraint(fk)
    }

    // MARK: - Schema Switching

    func switchSchema(to schema: String) async throws {
        guard let core else { throw OraclePluginError(core: .notConnected) }
        do {
            _ = try await core.executeSessionSetup(OracleSchemaQueries.setCurrentSchema(schema))
        } catch let error as OracleCoreError {
            throw error.asPluginError
        }
        sessionSchema.withLock { $0 = schema }
        core.noteSessionSchema(schema)
    }

    // Oracle has no database apart from its schemas, so tab restore's database switch is a schema switch.
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
        OracleBrowseSQL.browseQuery(
            qualifiedTable: OracleBrowseSQL.qualifiedName(schema: schema, table: table),
            sortColumns: sortColumns, columns: columns, limit: limit, offset: offset
        )
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
        OracleBrowseSQL.filteredQuery(
            qualifiedTable: OracleBrowseSQL.qualifiedName(schema: schema, table: table),
            filters: queryFilters,
            logicMode: logicMode,
            sortColumns: sortColumns,
            columns: columns,
            limit: limit,
            offset: offset,
            columnKinds: columnKinds
        )
    }

    // MARK: - Private Helpers

    // Set at login before `core` is, so a driver with a core always has it.
    func serverRelease() throws -> OracleServerRelease {
        guard let release = core?.serverRelease else { throw OraclePluginError(core: .notConnected) }
        return release
    }

    // Without a core every read fails as not connected, so building the catalog fails the same way.
    var exportCatalog: OracleExportCatalog {
        get throws {
            OracleExportCatalog(
                run: { [self] query in try await rawQuery(query) },
                currentSchema: currentSchema,
                fallbackSchema: config.username.uppercased(),
                release: try serverRelease(),
                principalState: principalState,
                coreError: { ($0 as? OraclePluginError)?.core }
            )
        }
    }

    func effectiveSchema(_ schema: String?) -> String {
        schema ?? currentSchema ?? config.username.uppercased()
    }
}
