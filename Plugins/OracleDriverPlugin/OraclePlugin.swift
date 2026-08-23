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

    func diagnose(error: Error) -> PluginDiagnostic? {
        guard let oracleError = (error as? OraclePluginError)?.core else { return nil }
        let message = oracleError.errorDescription ?? ""
        let issuesURL = URL(string: "https://github.com/TableProApp/TablePro/issues")
        switch oracleError {
        case .authVerifierUnsupported(let flag):
            return PluginDiagnostic(
                title: String(localized: "Unsupported Password Verifier"),
                message: message,
                suggestedActions: [
                    String(localized: "Verify the user account exists and the password is correct."),
                    String(localized: "Ask your DBA to confirm the user has an 11G or 12C password verifier (SELECT password_versions FROM dba_users WHERE username = '<USER>')."),
                    String(localized: "If the verifier is brand-new (e.g. 23ai), file an issue with the verifier flag below.")
                ],
                diagnosticInfo: [
                    DiagnosticEntry(label: "Verifier flag", value: flag)
                ],
                supportURL: issuesURL
            )
        case .authConnectionDropped(let phase):
            return PluginDiagnostic(
                title: String(localized: "Connection Dropped During Handshake"),
                message: message,
                suggestedActions: [
                    String(localized: "Check for a firewall, VPN, or load balancer between you and the server that closes connections mid-handshake."),
                    String(localized: "If the listener endpoint is TLS-only (TCPS), set the SSL mode in the connection's SSL settings."),
                    String(localized: "Confirm the host and port reach the database listener directly, not a proxy that resets unknown traffic."),
                    String(localized: "If this is Oracle 11g, open an issue and include the handshake phase shown below.")
                ],
                diagnosticInfo: phase.map { [DiagnosticEntry(label: String(localized: "Handshake phase"), value: $0)] } ?? [],
                supportURL: URL(string: "https://github.com/TableProApp/TablePro/issues/483")
            )
        case .authVersionNotSupported:
            return PluginDiagnostic(
                title: String(localized: "Server Version Not Supported"),
                message: message,
                suggestedActions: [
                    String(localized: "TablePro supports Oracle Database 11.1 and later. This server reports an older release (10g or earlier)."),
                    String(localized: "Upgrade the database to 11.2 or later, or connect with a client that bundles Oracle's OCI client such as SQL Developer or DataGrip.")
                ],
                supportURL: issuesURL
            )
        case .protocolError:
            return PluginDiagnostic(
                title: String(localized: "Connection Reset"),
                message: message,
                suggestedActions: [
                    String(localized: "Run the query again. TablePro reconnects to the server automatically."),
                    String(localized: "If the same query keeps failing, the server may be returning data the driver cannot decode. File an issue with your Oracle version.")
                ],
                supportURL: URL(string: "https://github.com/TableProApp/TablePro/issues/483")
            )
        case .nativeEncryptionFailed:
            return PluginDiagnostic(
                title: String(localized: "Native Network Encryption Not Completed"),
                message: message,
                suggestedActions: [
                    String(localized: "The server requires Oracle native network encryption, and negotiating it with this server did not complete."),
                    String(localized: "Ask the DBA which encryption and checksum algorithms the server requires. The driver supports AES with a SHA-2 checksum."),
                    String(localized: "File an issue with your Oracle version and the details below so the driver can add support.")
                ],
                supportURL: issuesURL
            )
        case .loginTimedOut:
            return PluginDiagnostic(
                title: String(localized: "Login Handshake Timed Out"),
                message: message,
                suggestedActions: [
                    String(localized: "Check for a firewall, VPN, or proxy between you and the server that stalls connections after the TCP handshake."),
                    String(localized: "Confirm the host and port reach the database listener directly.")
                ],
                supportURL: issuesURL
            )
        case .queryTimedOut:
            return PluginDiagnostic(
                title: String(localized: "Query Timed Out"),
                message: message,
                suggestedActions: [
                    String(localized: "Run the query again. TablePro reconnects to the server automatically."),
                    String(localized: "If the query legitimately needs more time, raise the query timeout in Settings > General."),
                    String(localized: "If a metadata query timed out, the schema may hold a very large number of objects; try again once the server is less busy.")
                ],
                supportURL: issuesURL
            )
        case .certificateUnavailable:
            return PluginDiagnostic(
                title: String(localized: "Certificate Not Available"),
                message: message,
                suggestedActions: [
                    String(localized: "Check the certificate paths in the connection's SSL settings."),
                    String(localized: "Certificate files are not part of a synced connection, so a connection set up on another device needs its certificates added here.")
                ],
                supportURL: issuesURL
            )
        case .notConnected, .connectionFailed, .queryFailed, .cancelled, .tlsHandshakeFailed:
            return nil
        }
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
            tls: config.ssl.oracleTLSDescription
        ))
        do {
            try await connection.connect()
        } catch let error as OracleCoreError {
            throw error.asPluginError
        }
        self.core = connection

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
        // Oracle uses implicit transactions — no explicit BEGIN needed
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> PluginQueryResult {
        let startTime = Date()

        // Health monitor sends "SELECT 1" as a ping; Oracle requires FROM DUAL.
        let isBareSelectOne = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "select 1"
        var result = try await rawQuery(isBareSelectOne ? OracleSchemaQueries.ping : query)
        let executionTime = Date().timeIntervalSince(startTime)

        // OracleNIO may not populate column metadata for empty result sets.
        if result.columns.isEmpty, result.rows.isEmpty,
           let recovered = try? await emptyResultColumns(for: query) {
            result = recovered
        }

        return result.toPluginResult(executionTime: executionTime)
    }

    private func rawQuery(_ query: String) async throws -> OracleRawResult {
        guard let core else { throw OraclePluginError(core: .notConnected) }
        do {
            return try await core.executeQuery(query)
        } catch let error as OracleCoreError {
            throw error.asPluginError
        }
    }

    private func emptyResultColumns(for query: String) async throws -> OracleRawResult? {
        guard let table = Self.extractTableNameFromSelect(query) else { return nil }
        let sql = """
            SELECT COLUMN_NAME, DATA_TYPE FROM ALL_TAB_COLUMNS \
            WHERE OWNER = '\(effectiveSchemaEscaped(nil))' \
            AND TABLE_NAME = '\(OracleSchemaQueries.escapeLiteral(table))' \
            ORDER BY COLUMN_ID
            """
        let columns = try await rawQuery(sql).rows.compactMap { row -> OracleColumnDescriptor? in
            guard let name = row.first?.stringValue else { return nil }
            let typeName = (row.count > 1 ? row[1].stringValue : nil)?.lowercased() ?? "varchar2"
            return OracleColumnDescriptor(name: name, typeName: typeName)
        }
        guard !columns.isEmpty else { return nil }
        return OracleRawResult(columns: columns, rows: [], affectedRows: 0, isTruncated: false)
    }

    // MARK: - Streaming

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        guard let core else {
            return AsyncThrowingStream { $0.finish(throwing: OraclePluginError(core: .notConnected)) }
        }

        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let streamTask = Task {
                let coreStream = AsyncThrowingStream<OracleStreamElement, Error> { coreContinuation in
                    Task {
                        do {
                            try await core.streamQuery(query, continuation: coreContinuation)
                        } catch {
                            coreContinuation.finish(throwing: error)
                        }
                    }
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
            continuation.onTermination = { @Sendable _ in
                streamTask.cancel()
            }
        }
    }

    // MARK: - Schema Operations

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        let result = try await rawQuery(OracleSchemaQueries.tables(schema: effectiveSchema(schema)))
        return result.rows.compactMap(OracleSchemaQueries.parseTableRow).map {
            PluginTableInfo(name: $0.name, type: $0.isView ? "VIEW" : "TABLE")
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
        "DROP TRIGGER \"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        let escaped = effectiveSchemaEscaped(schema)
        let sql = """
            SELECT
                c.TABLE_NAME,
                c.COLUMN_NAME,
                c.DATA_TYPE,
                c.DATA_LENGTH,
                c.DATA_PRECISION,
                c.DATA_SCALE,
                c.NULLABLE,
                CASE WHEN cc.COLUMN_NAME IS NOT NULL THEN 'Y' ELSE 'N' END AS IS_PK
            FROM ALL_TAB_COLUMNS c
            LEFT JOIN (
                SELECT acc.TABLE_NAME, acc.COLUMN_NAME
                FROM ALL_CONS_COLUMNS acc
                JOIN ALL_CONSTRAINTS ac ON acc.CONSTRAINT_NAME = ac.CONSTRAINT_NAME
                    AND acc.OWNER = ac.OWNER
                WHERE ac.CONSTRAINT_TYPE = 'P' AND ac.OWNER = '\(escaped)'
            ) cc ON c.TABLE_NAME = cc.TABLE_NAME AND c.COLUMN_NAME = cc.COLUMN_NAME
            WHERE c.OWNER = '\(escaped)'
            ORDER BY c.TABLE_NAME, c.COLUMN_ID
            """
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
        let escaped = effectiveSchemaEscaped(schema)
        let sql = """
            SELECT
                ac.TABLE_NAME,
                ac.CONSTRAINT_NAME,
                acc.COLUMN_NAME,
                rc.TABLE_NAME AS REF_TABLE,
                rcc.COLUMN_NAME AS REF_COLUMN,
                ac.DELETE_RULE,
                rc.OWNER AS REF_SCHEMA
            FROM ALL_CONSTRAINTS ac
            JOIN ALL_CONS_COLUMNS acc ON ac.CONSTRAINT_NAME = acc.CONSTRAINT_NAME
                AND ac.OWNER = acc.OWNER
            JOIN ALL_CONSTRAINTS rc ON ac.R_CONSTRAINT_NAME = rc.CONSTRAINT_NAME
                AND ac.R_OWNER = rc.OWNER
            JOIN ALL_CONS_COLUMNS rcc ON rc.CONSTRAINT_NAME = rcc.CONSTRAINT_NAME
                AND rc.OWNER = rcc.OWNER AND acc.POSITION = rcc.POSITION
            WHERE ac.CONSTRAINT_TYPE = 'R' AND ac.OWNER = '\(escaped)'
            ORDER BY ac.TABLE_NAME, ac.CONSTRAINT_NAME, acc.POSITION
            """
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
        let sql = """
            SELECT u.USERNAME,
                   NVL(t.table_count, 0) AS table_count,
                   NVL(s.size_bytes, 0) AS size_bytes
            FROM ALL_USERS u
            LEFT JOIN (
                SELECT OWNER, COUNT(*) AS table_count FROM ALL_TABLES GROUP BY OWNER
            ) t ON u.USERNAME = t.OWNER
            LEFT JOIN (
                SELECT OWNER, SUM(BYTES) AS size_bytes FROM ALL_SEGMENTS GROUP BY OWNER
            ) s ON u.USERNAME = s.OWNER
            ORDER BY u.USERNAME
            """
        let result = try await execute(query: sql)
        return result.rows.compactMap { row -> PluginDatabaseMetadata? in
            guard let name = row[safe: 0]?.asText else { return nil }
            let tableCount = (row[safe: 1]?.asText).flatMap { Int($0) } ?? 0
            let sizeBytes = (row[safe: 2]?.asText).flatMap { Int64($0) }
            return PluginDatabaseMetadata(name: name, tableCount: tableCount, sizeBytes: sizeBytes)
        }
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
        let escapedView = view.replacingOccurrences(of: "'", with: "''")
        let escaped = effectiveSchemaEscaped(schema)
        // ALL_VIEWS.TEXT is LONG (crashes OracleNIO). TEXT_VC is VARCHAR2(4000), safe.
        // Do NOT use DBMS_METADATA.GET_DDL — wrong object type triggers ORA-31603
        // which corrupts OracleNIO's connection state machine.
        let sql = "SELECT TEXT_VC FROM ALL_VIEWS WHERE VIEW_NAME = '\(escapedView)' AND OWNER = '\(escaped)'"
        let result = try await execute(query: sql)
        return result.rows.first?.first?.asText ?? ""
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")
        let escaped = effectiveSchemaEscaped(schema)
        let sql = """
            SELECT
                t.NUM_ROWS,
                s.BYTES,
                tc.COMMENTS
            FROM ALL_TABLES t
            LEFT JOIN ALL_SEGMENTS s ON t.TABLE_NAME = s.SEGMENT_NAME AND t.OWNER = s.OWNER
            LEFT JOIN ALL_TAB_COMMENTS tc ON t.TABLE_NAME = tc.TABLE_NAME AND t.OWNER = tc.OWNER
            WHERE t.TABLE_NAME = '\(escapedTable)' AND t.OWNER = '\(escaped)'
            """
        let result = try await execute(query: sql)
        if let row = result.rows.first {
            let rowCount = (row[safe: 0]?.asText).flatMap { Int64($0) }
            let sizeBytes = (row[safe: 1]?.asText).flatMap { Int64($0) } ?? 0
            let comment = row[safe: 2]?.asText
            return PluginTableMetadata(
                tableName: table,
                dataSize: sizeBytes,
                totalSize: sizeBytes,
                rowCount: rowCount,
                comment: comment
            )
        }

        // Fallback for views: ALL_TABLES returns no rows for views
        let viewSQL = """
            SELECT tc.COMMENTS
            FROM ALL_TAB_COMMENTS tc
            WHERE tc.TABLE_NAME = '\(escapedTable)' AND tc.OWNER = '\(escaped)'
            """
        let viewResult = try await execute(query: viewSQL)
        if let row = viewResult.rows.first {
            let comment = row[safe: 0]?.asText
            return PluginTableMetadata(tableName: table, comment: comment)
        }

        return PluginTableMetadata(tableName: table)
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
        let escapedDb = database.replacingOccurrences(of: "'", with: "''")
        let sql = """
            SELECT
                (SELECT COUNT(*) FROM ALL_TABLES WHERE OWNER = '\(escapedDb)') AS table_count,
                (SELECT NVL(SUM(BYTES), 0) FROM ALL_SEGMENTS WHERE OWNER = '\(escapedDb)') AS size_bytes
            FROM DUAL
            """
        do {
            let result = try await execute(query: sql)
            if let row = result.rows.first {
                let tableCount = (row[safe: 0]?.asText).flatMap { Int($0) } ?? 0
                let sizeBytes = (row[safe: 1]?.asText).flatMap { Int64($0) } ?? 0
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

        var sql = "CREATE TABLE \(qualifiedTable) (\n  " +
            parts.joined(separator: ",\n  ") +
            "\n);"

        var indexStatements: [String] = []
        for index in definition.indexes {
            indexStatements.append(oracleIndexDefinition(index, qualifiedTable: qualifiedTable))
        }
        if !indexStatements.isEmpty {
            sql += "\n\n" + indexStatements.joined(separator: ";\n") + ";"
        }

        return sql
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
                def += " DEFAULT \(oracleDefaultValue(defaultValue))"
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
            def += " DEFAULT \(oracleDefaultValue(defaultValue))"
        }
        if !col.isNullable {
            def += " NOT NULL"
        }
        if inlinePK && col.isPrimaryKey {
            def += " PRIMARY KEY"
        }
        return def
    }

    private func oracleDefaultValue(_ value: String) -> String {
        let upper = value.uppercased()
        if upper == "NULL" || upper == "SYSDATE" || upper == "SYSTIMESTAMP"
            || upper == "SYS_GUID()" || upper == "USER"
            || value.hasPrefix("'") || Int64(value) != nil || Double(value) != nil {
            return value
        }
        return "'\(escapeStringLiteral(value))'"
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
        var def = "CONSTRAINT \(quoteIdentifier(fk.name)) FOREIGN KEY (\(cols)) REFERENCES \(refTable) (\(refCols))"
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
        let s = schema ?? currentSchema ?? "SYSTEM"
        return """
        SELECT
            OWNER as schema_name,
            TABLE_NAME as name,
            'TABLE' as kind,
            NUM_ROWS as estimated_rows
        FROM ALL_TABLES
        WHERE OWNER = '\(s)'
        ORDER BY TABLE_NAME
        """
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
