import Foundation
import TableProPluginKit

final class DamengPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Dameng Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Dameng DM8 support via a native wire driver"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "Dameng"
    static let databaseDisplayName = "Dameng DM8"
    static let iconName = "cylinder"
    static let defaultPort = 5_236
    static let isDownloadable = true
    static let urlSchemes = ["dm"]
    static let brandColorHex = "#C60018"
    static let supportsSSL = false
    static let supportsDatabaseSwitching = false
    static let supportsSchemaSwitching = true
    static let supportsRoutines = true
    static let supportsDatabaseTriggerBrowse = true
    static let defaultSchemaName = ""
    static let containerEntityName = "Schema"
    static let postConnectActions: [PostConnectAction] = [.selectSchemaFromLastSession]
    static let explainVariants = [
        ExplainVariant(id: "plan", label: "Plan", sqlPrefix: "EXPLAIN", format: .damengText)
    ]
    static let databaseGroupingStrategy: GroupingStrategy = .hierarchicalSchema
    static let pathFieldRole: PathFieldRole = .database
    static let systemSchemaNames = ["SYS", "SYSDBA", "SYSAUDITOR", "SYSSSO", "CTISYS"]
    static let supportsCascadeDrop = true
    static let supportsDropSchema = true
    static let supportsForeignKeyDisable = false
    static let supportsRenameColumn = true
    static let columnTypesByCategory: [String: [String]] = [
        "Integer": ["TINYINT", "SMALLINT", "INT", "INTEGER", "BIGINT"],
        "Float": ["REAL", "FLOAT", "DOUBLE", "DEC", "DECIMAL", "NUMERIC", "NUMBER"],
        "String": ["CHAR", "CHARACTER", "VARCHAR", "VARCHAR2", "TEXT", "CLOB"],
        "Date": ["DATE", "TIME", "DATETIME", "TIMESTAMP"],
        "Binary": ["BINARY", "VARBINARY", "BLOB", "IMAGE"],
        "Boolean": ["BIT", "BOOLEAN"],
        "Other": ["ROWID", "INTERVAL"]
    ]
    static let statementCompletions = [
        CompletionEntry(label: "SELECT", insertText: "SELECT"),
        CompletionEntry(label: "SELECT DISTINCT", insertText: "SELECT DISTINCT"),
        CompletionEntry(label: "INSERT INTO", insertText: "INSERT INTO"),
        CompletionEntry(label: "UPDATE", insertText: "UPDATE"),
        CompletionEntry(label: "DELETE FROM", insertText: "DELETE FROM"),
        CompletionEntry(label: "MERGE INTO", insertText: "MERGE INTO"),
        CompletionEntry(label: "CREATE TABLE", insertText: "CREATE TABLE"),
        CompletionEntry(label: "CREATE OR REPLACE VIEW", insertText: "CREATE OR REPLACE VIEW"),
        CompletionEntry(label: "CREATE SCHEMA", insertText: "CREATE SCHEMA"),
        CompletionEntry(label: "ALTER TABLE", insertText: "ALTER TABLE"),
        CompletionEntry(label: "DROP TABLE", insertText: "DROP TABLE"),
        CompletionEntry(label: "DROP SCHEMA", insertText: "DROP SCHEMA"),
        CompletionEntry(label: "SET SCHEMA", insertText: "SET SCHEMA"),
        CompletionEntry(label: "EXPLAIN", insertText: "EXPLAIN"),
        CompletionEntry(label: "WHERE", insertText: "WHERE"),
        CompletionEntry(label: "GROUP BY", insertText: "GROUP BY"),
        CompletionEntry(label: "ORDER BY", insertText: "ORDER BY"),
        CompletionEntry(label: "FETCH FIRST", insertText: "FETCH FIRST"),
        CompletionEntry(label: "JOIN", insertText: "JOIN"),
        CompletionEntry(label: "LEFT JOIN", insertText: "LEFT JOIN"),
        CompletionEntry(label: "UNION ALL", insertText: "UNION ALL"),
        CompletionEntry(label: "WITH", insertText: "WITH"),
        CompletionEntry(label: "CONNECT BY", insertText: "CONNECT BY"),
        CompletionEntry(label: "START WITH", insertText: "START WITH"),
        CompletionEntry(label: "PARTITION BY", insertText: "PARTITION BY")
    ]
    static let sqlDialect: SQLDialectDescriptor? = SQLDialectDescriptor(
        identifierQuote: "\"",
        keywords: [
            "SELECT", "FROM", "WHERE", "JOIN", "INNER", "LEFT", "RIGHT", "OUTER", "CROSS", "FULL",
            "ON", "USING", "AND", "OR", "NOT", "IN", "LIKE", "BETWEEN", "AS", "ORDER", "BY", "GROUP",
            "HAVING", "LIMIT", "OFFSET", "FETCH", "FIRST", "ROWS", "ONLY", "INSERT", "INTO", "VALUES",
            "UPDATE", "SET", "DELETE", "MERGE", "CREATE", "ALTER", "DROP", "TABLE", "INDEX", "VIEW",
            "SCHEMA", "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "CONSTRAINT", "ADD", "MODIFY",
            "COLUMN", "RENAME", "NULL", "IS", "ASC", "DESC", "DISTINCT", "ALL", "ANY", "SOME",
            "IDENTITY", "SEQUENCE", "SYNONYM", "GRANT", "REVOKE", "TRIGGER", "PROCEDURE", "CASE", "WHEN",
            "THEN", "ELSE", "END", "UNION", "INTERSECT", "MINUS", "DECLARE", "BEGIN", "COMMIT", "ROLLBACK",
            "SAVEPOINT", "EXECUTE", "IMMEDIATE", "OVER", "PARTITION", "ROW_NUMBER", "RANK", "DENSE_RANK",
            "CONNECT", "LEVEL", "START", "WITH", "PRIOR", "ROWNUM", "ROWID", "DUAL"
        ],
        functions: [
            "COUNT", "SUM", "AVG", "MAX", "MIN", "LISTAGG", "CONCAT", "SUBSTR", "INSTR", "LENGTH", "LOWER",
            "UPPER", "TRIM", "LTRIM", "RTRIM", "REPLACE", "LPAD", "RPAD", "SYSDATE", "CURRENT_DATE",
            "CURRENT_TIMESTAMP", "ADD_MONTHS", "MONTHS_BETWEEN", "LAST_DAY", "EXTRACT", "TO_DATE", "TO_CHAR",
            "TO_NUMBER", "TO_TIMESTAMP", "TRUNC", "ROUND", "CEIL", "FLOOR", "ABS", "POWER", "SQRT", "MOD",
            "NVL", "NVL2", "COALESCE", "NULLIF", "GREATEST", "LEAST", "CAST", "USER"
        ],
        dataTypes: Set(columnTypesByCategory.values.flatMap { $0 }),
        tableOptions: ["TABLESPACE", "STORAGE", "PCTFREE", "INITRANS"],
        regexSyntax: .regexpLike,
        booleanLiteralStyle: .numeric,
        likeEscapeStyle: .explicit,
        paginationStyle: .offsetFetch,
        offsetFetchOrderBy: "ORDER BY 1",
        autoLimitStyle: .fetchFirst,
        caseSensitivityStyle: .caseFoldFunction
    )

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        DamengPluginDriver(config: config)
    }
}

final class DamengPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    /// The session state a rebuilt connection has to be put back into. Guarded because a
    /// reconnect now runs from any statement's task, not only from connect and disconnect.
    struct SessionState {
        var activeSchema: String?
        var textEscaping: DamengTextEscaping = .unknown
        /// A driver that never reached the server has nothing to reconnect to, so a closed
        /// connection there is the connect failing rather than a session to rebuild.
        var hasConnectedBefore = false
        var openTransactions = 0
    }

    let config: DriverConnectionConfig
    let connection = DamengConnection()
    private let cancellationGate = PluginQueryCancellationGate()
    private var detectedServerVersion: String?

    let sessionLock = NSLock()
    var sessionState = SessionState()

    /// Concurrent callers await one rebuild instead of each starting their own, which would
    /// have each retired the connection the previous one had just adopted.
    var reconnectInFlight: Task<Void, any Error>?
    var reconnectGeneration: UInt64 = 0

    var activeSchema: String? {
        get { sessionLock.withLock { sessionState.activeSchema } }
        set { sessionLock.withLock { sessionState.activeSchema = newValue } }
    }

    var textEscaping: DamengTextEscaping {
        get { sessionLock.withLock { sessionState.textEscaping } }
        set { sessionLock.withLock { sessionState.textEscaping = newValue } }
    }

    var hasConnectedBefore: Bool {
        get { sessionLock.withLock { sessionState.hasConnectedBefore } }
        set { sessionLock.withLock { sessionState.hasConnectedBefore = newValue } }
    }

    var hasOpenTransaction: Bool {
        sessionLock.withLock { sessionState.openTransactions > 0 }
    }

    var capabilities: PluginCapabilities {
        [.parameterizedQueries, .transactions, .alterTableDDL, .multiSchema]
    }

    var supportsSchemas: Bool { true }
    var supportsTransactions: Bool { true }
    var currentSchema: String? { activeSchema }
    var serverVersion: String? { detectedServerVersion }

    init(config: DriverConnectionConfig) {
        self.config = config
    }

    func connect() async throws {
        try await connection.connect(
            host: config.host,
            port: config.port,
            username: config.username,
            password: config.password
        )
        textEscaping = await detectTextEscaping()
        do {
            let initialSchema = config.database.trimmingCharacters(in: .whitespacesAndNewlines)
            if !initialSchema.isEmpty {
                try await applySchema(initialSchema)
            } else {
                activeSchema = try await scalarText("SELECT SF_GET_SCHEMA_NAME_BY_ID(CURRENT_SCHID)")
            }
        } catch {
            disconnect()
            throw error
        }
        detectedServerVersion = (try? await scalarText("SELECT BANNER FROM V$VERSION WHERE ROWNUM = 1"))
            .map { String($0.prefix(60)) }
        hasConnectedBefore = true
    }

    /// Keeps the mode the previous connection established when the probe fails, because
    /// `.unknown` refuses every value containing a backslash for the rest of the session.
    func detectTextEscaping() async -> DamengTextEscaping {
        guard let length = try? await scalarText("SELECT LENGTH('\\\\') FROM DUAL") else {
            return textEscaping
        }
        switch length.trimmingCharacters(in: .whitespaces).prefix(1) {
        case "2": return .backslashLiteral
        case "1": return .backslashEscape
        default: return .unknown
        }
    }

    func disconnect() {
        cancelReconnect()
        connection.disconnect()
        activeSchema = nil
        detectedServerVersion = nil
        textEscaping = .unknown
        hasConnectedBefore = false
    }

    /// A rebuild that outlived the caller would open a DM8 session after the user closed the
    /// connection, and repopulate the schema on a driver the app considers disconnected.
    func cancelReconnect() {
        let inFlight = sessionLock.withLock { () -> Task<Void, any Error>? in
            let task = reconnectInFlight
            reconnectInFlight = nil
            return task
        }
        inFlight?.cancel()
    }

    func ping() async throws {
        try await connection.ping()
    }

    /// DM8 has no out-of-band cancel request, so stopping abandons the reply and closes the
    /// connection. The app reconnects on the next statement.
    func cancelQuery() throws {
        cancellationGate.cancel()
        connection.cancelInFlightStatement()
    }

    func applyQueryTimeout(_ seconds: Int) async throws {
        connection.applyQueryTimeout(seconds: seconds)
    }

    func execute(query: String) async throws -> PluginQueryResult {
        try await executeWithReconnect(
            query: query, parameters: [], rowCap: nil, replay: replayPolicy(for: query)
        )
    }

    func executeUserQuery(
        query: String,
        rowCap: Int?,
        parameters: [PluginCellValue]?
    ) async throws -> PluginQueryResult {
        try await executeWithReconnect(
            query: query,
            parameters: parameters ?? [],
            rowCap: rowCap,
            replay: replayPolicy(for: query)
        )
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        try await executeWithReconnect(
            query: query, parameters: parameters, rowCap: nil, replay: replayPolicy(for: query)
        )
    }

    /// Every statement in a script has to be a read, not just the first one. A script now
    /// really executes, so `SELECT ...; DELETE ...` classified on its leading keyword alone
    /// would replay the delete on a rebuilt connection.
    func replayPolicy(for query: String) -> DamengReplayPolicy {
        let statements = DamengScriptSplitter.statements(in: query, escaping: textEscaping)
        guard !statements.isEmpty else { return .reportFailure }
        return statements.allSatisfy(DamengStatementClassifier.isReadOnly) ? .replayable : .reportFailure
    }

    func beginTransaction() async throws {
        try await connection.beginTransaction()
        sessionLock.withLock { sessionState.openTransactions += 1 }
    }

    /// The count drops whether or not the server accepted the end, because a failure means the
    /// transaction is over too. Leaving it raised would refuse every later reconnect.
    func commitTransaction() async throws {
        defer { endTransaction() }
        try await connection.commitTransaction()
    }

    func rollbackTransaction() async throws {
        defer { endTransaction() }
        try await connection.rollbackTransaction()
    }

    func endTransaction() {
        sessionLock.withLock { sessionState.openTransactions = max(0, sessionState.openTransactions - 1) }
    }

    func switchSchema(to schema: String) async throws {
        let normalized = schema.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw DamengError(message: String(localized: "The Dameng schema name cannot be empty."))
        }
        do {
            try await applySchema(normalized)
        } catch let error as DamengError where error.closedConnection && hasOpenTransaction {
            // Rebuilding under an open transaction would leave the count raised on a session
            // that never saw the BEGIN, and the later commit would report success regardless.
            endTransaction()
            throw DamengError(message: String(localized: """
                The Dameng connection was lost, so the open transaction was rolled back. \
                Run its statements again.
                """))
        } catch let error as DamengError where error.closedConnection && hasConnectedBefore {
            try await reconnect(restoringSchema: normalized)
        }
    }

    /// Moves the session onto `schema` and confirms the server agrees.
    ///
    /// `SET SCHEMA` is wrapped in an anonymous block because DM8 rejects it as a prepared
    /// statement: sent bare over the wire the server answers with a truncated frame and the
    /// driver reports "incomplete protocol data", which also desyncs the connection.
    func applySchema(_ schema: String) async throws {
        let setSchema = "SET SCHEMA \(quoteIdentifier(schema))"
        let escaped = try DamengParameterBinder.escapedText(setSchema, escaping: textEscaping)
        _ = try await executeOnce(
            query: "BEGIN EXECUTE IMMEDIATE '\(escaped)'; END;",
            parameters: [],
            rowCap: nil
        )
        let selected = try await scalarText("SELECT SF_GET_SCHEMA_NAME_BY_ID(CURRENT_SCHID)")
        guard selected.caseInsensitiveCompare(schema) == .orderedSame else {
            throw DamengError(message: String(localized: "Dameng did not switch to the requested schema."))
        }
        activeSchema = selected
    }

    func dropSchema(name: String) async throws {
        guard !DamengPlugin.systemSchemaNames.contains(name.uppercased()) else {
            throw DamengError(message: String(localized: "Dameng system schemas cannot be dropped."))
        }
        guard name.caseInsensitiveCompare(activeSchema ?? "") != .orderedSame else {
            throw DamengError(message: String(localized: "Switch away from a schema before dropping it."))
        }
        _ = try await execute(query: "DROP SCHEMA \(quoteIdentifier(name)) CASCADE")
    }

    func quoteIdentifier(_ name: String) -> String {
        var quoted = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            if scalar == "\"" { quoted.append(scalar) }
            quoted.append(scalar)
        }
        return "\"\(String(quoted))\""
    }

    var requiresBackslashEscapingInLiterals: Bool { textEscaping == .backslashEscape }

    func escapeStringLiteral(_ value: String) -> String {
        let stripped = String(String.UnicodeScalarView(value.unicodeScalars.filter { $0 != "\0" }))
        let escaping: DamengTextEscaping = textEscaping == .backslashLiteral ? .backslashLiteral : .backslashEscape
        return (try? DamengParameterBinder.escapedText(stripped, escaping: escaping)) ?? stripped
    }

    func createViewTemplate() -> String? {
        "CREATE OR REPLACE VIEW view_name AS\nSELECT column1, column2\nFROM table_name\nWHERE condition;"
    }

    func editViewFallbackTemplate(viewName: String) -> String? {
        "CREATE OR REPLACE VIEW \(quoteIdentifier(viewName)) AS\nSELECT * FROM table_name;"
    }

    func castColumnToText(_ column: String) -> String {
        "CAST(\(column) AS VARCHAR(8188))"
    }

    func buildExplainQuery(_ sql: String) -> String? {
        "EXPLAIN \(sql)"
    }

    /// DM8 rejects a string holding more than one statement, so a script is sent a statement at
    /// a time and the last one's result is returned. A single statement is passed through
    /// untouched, terminator and all, so nothing changes for the common path.
    func executeOnce(
        query: String,
        parameters: [PluginCellValue],
        rowCap: Int?
    ) async throws -> PluginQueryResult {
        let bound = parameters.isEmpty
            ? query
            : try DamengParameterBinder.bind(query: query, parameters: parameters, escaping: textEscaping)
        let statements = DamengScriptSplitter.statements(in: bound, escaping: textEscaping)
        let generation = cancellationGate.beginQuery()
        defer { cancellationGate.endQuery(generation) }

        guard statements.count > 1 else {
            return try await runOne(bound, rowCap: rowCap, generation: generation)
        }
        var last: PluginQueryResult?
        for (offset, statement) in statements.enumerated() {
            do {
                last = try await runOne(statement, rowCap: rowCap, generation: generation)
            } catch let error as DamengError {
                // Naming the statement matters because the ones before it already ran and
                // cannot be rolled back: DM8 commits DDL as it goes.
                throw DamengError(
                    message: String(
                        format: String(localized: "Statement %1$d of %2$d failed: %3$@"),
                        offset + 1, statements.count, error.message
                    ),
                    closedConnection: error.closedConnection
                )
            }
        }
        guard let last else {
            throw DamengError(message: String(localized: "This Dameng script contains no statement to run."))
        }
        return last
    }

    private func runOne(
        _ statement: String,
        rowCap: Int?,
        generation: Int
    ) async throws -> PluginQueryResult {
        let expectsRows = DamengStatementClassifier.likelyReturnsRows(statement)
        let result = try await connection.execute(statement, expectsRows: expectsRows, rowCap: rowCap)
        if cancellationGate.isCancelled(generation) {
            throw CancellationError()
        }
        return PluginQueryResult(
            columns: result.columns,
            columnTypeNames: result.columnTypeNames,
            rows: result.rows,
            rowsAffected: result.rowsAffected,
            executionTime: result.executionTime,
            isTruncated: result.isTruncated
        )
    }

    /// Session probes run on the connection they are given: they are the statements a
    /// reconnect is made of, so routing them back through the retry would recurse.
    private func scalarText(_ query: String) async throws -> String {
        let result = try await executeOnce(query: query, parameters: [], rowCap: 1)
        guard let value = result.rows.first?.first?.asText else {
            throw DamengError(message: String(localized: "Dameng returned an empty metadata result."))
        }
        return value
    }
}
