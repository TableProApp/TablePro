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
    let config: DriverConnectionConfig
    private let connection = DamengConnection()
    private var activeSchema: String?
    private var detectedServerVersion: String?
    private var textEscaping: DamengTextEscaping = .unknown

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
            if !config.database.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await switchSchema(to: config.database)
            } else {
                activeSchema = try await scalarText("SELECT SF_GET_SCHEMA_NAME_BY_ID(CURRENT_SCHID)")
            }
        } catch {
            disconnect()
            throw error
        }
        detectedServerVersion = (try? await scalarText("SELECT BANNER FROM V$VERSION WHERE ROWNUM = 1"))
            .map { String($0.prefix(60)) }
    }

    private func detectTextEscaping() async -> DamengTextEscaping {
        guard let length = try? await scalarText("SELECT LENGTH('\\\\') FROM DUAL") else {
            return .unknown
        }
        switch length.trimmingCharacters(in: .whitespaces).prefix(1) {
        case "2": return .backslashLiteral
        case "1": return .backslashEscape
        default: return .unknown
        }
    }

    func disconnect() {
        connection.disconnect()
        activeSchema = nil
        detectedServerVersion = nil
        textEscaping = .unknown
    }

    func ping() async throws {
        try await connection.ping()
    }

    func execute(query: String) async throws -> PluginQueryResult {
        try await executeBound(query: query, parameters: [], rowCap: nil)
    }

    func executeUserQuery(
        query: String,
        rowCap: Int?,
        parameters: [PluginCellValue]?
    ) async throws -> PluginQueryResult {
        try await executeBound(query: query, parameters: parameters ?? [], rowCap: rowCap)
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        try await executeBound(query: query, parameters: parameters, rowCap: nil)
    }

    func beginTransaction() async throws {
        try await connection.beginTransaction()
    }

    func commitTransaction() async throws {
        try await connection.commitTransaction()
    }

    func rollbackTransaction() async throws {
        try await connection.rollbackTransaction()
    }

    func switchSchema(to schema: String) async throws {
        let normalized = schema.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw DamengError(message: String(localized: "The Dameng schema name cannot be empty."))
        }
        let setSchema = "SET SCHEMA \(quoteIdentifier(normalized))"
        let escaped = try DamengParameterBinder.escapedText(setSchema, escaping: textEscaping)
        _ = try await executeBound(
            query: "BEGIN EXECUTE IMMEDIATE '\(escaped)'; END;",
            parameters: [],
            rowCap: nil
        )
        let selected = try await scalarText("SELECT SF_GET_SCHEMA_NAME_BY_ID(CURRENT_SCHID)")
        guard selected.caseInsensitiveCompare(normalized) == .orderedSame else {
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

    private func executeBound(
        query: String,
        parameters: [PluginCellValue],
        rowCap: Int?
    ) async throws -> PluginQueryResult {
        let bound = parameters.isEmpty
            ? query
            : try DamengParameterBinder.bind(query: query, parameters: parameters, escaping: textEscaping)
        let expectsRows = DamengStatementClassifier.expectsRows(bound)
        let result = try await connection.execute(bound, expectsRows: expectsRows, rowCap: rowCap)
        if rowCap == nil, result.isTruncated {
            let format = String(localized: """
                This Dameng query returned more than %lld rows, which is the most TablePro reads at once. \
                Add a WHERE clause or a row limit and try again.
                """)
            throw DamengError(message: String(format: format, Int64(PluginRowLimits.emergencyMax)))
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

    private func scalarText(_ query: String) async throws -> String {
        let result = try await executeBound(query: query, parameters: [], rowCap: 1)
        guard let value = result.rows.first?.first?.asText else {
            throw DamengError(message: String(localized: "Dameng returned an empty metadata result."))
        }
        return value
    }
}
