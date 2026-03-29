//
//  OraclePlugin.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

final class OraclePlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Oracle Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Oracle Database support via OracleNIO"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "Oracle"
    static let databaseDisplayName = "Oracle"
    static let iconName = "oracle-icon"
    static let defaultPort = 1521
    static let additionalConnectionFields: [ConnectionField] = [
        ConnectionField(id: "oracleServiceName", label: "Service Name", placeholder: "ORCL")
    ]

    // MARK: - UI/Capability Metadata

    static let isDownloadable = true
    static let pathFieldRole: PathFieldRole = .serviceName
    static let supportsForeignKeyDisable = false
    static let brandColorHex = "#C3160B"
    static let systemDatabaseNames: [String] = ["SYS", "SYSTEM", "OUTLN", "DBSNMP", "APPQOSSYS", "WMSYS", "XDB"]
    static let databaseGroupingStrategy: GroupingStrategy = .bySchema
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
        autoLimitStyle: .fetchFirst
    )

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        OraclePluginDriver(config: config)
    }
}

final class OraclePluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let config: DriverConnectionConfig
    private var oracleConn: OracleConnectionWrapper?
    private var _currentSchema: String?
    private var _serverVersion: String?

    private static let logger = Logger(subsystem: "com.TablePro", category: "OraclePluginDriver")

    var currentSchema: String? { _currentSchema }
    var serverVersion: String? { _serverVersion }
    var supportsSchemas: Bool { true }
    var supportsTransactions: Bool { true }

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
        let serviceName = config.additionalFields["oracleServiceName"] ?? ""
        let conn = OracleConnectionWrapper(
            host: config.host,
            port: config.port,
            user: config.username,
            password: config.password,
            database: config.database,
            serviceName: serviceName
        )
        try await conn.connect()
        self.oracleConn = conn

        if let result = try? await conn.executeQuery("SELECT SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA') FROM DUAL"),
           let schema = result.rows.first?.first ?? nil {
            _currentSchema = schema
        } else {
            _currentSchema = config.username.uppercased()
        }

        if let result = try? await conn.executeQuery("SELECT BANNER FROM V$VERSION WHERE ROWNUM = 1"),
           let versionStr = result.rows.first?.first ?? nil {
            _serverVersion = String(versionStr.prefix(60))
        }
    }

    func disconnect() {
        oracleConn?.disconnect()
        oracleConn = nil
    }

    func ping() async throws {
        _ = try await execute(query: "SELECT 1 FROM DUAL")
    }

    // MARK: - Transaction Management

    func beginTransaction() async throws {
        // Oracle uses implicit transactions — no explicit BEGIN needed
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> PluginQueryResult {
        guard let conn = oracleConn else {
            throw OracleError.notConnected
        }
        let startTime = Date()

        // Health monitor sends "SELECT 1" as a ping; Oracle requires FROM DUAL.
        var effectiveQuery = query
        if query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "select 1" {
            effectiveQuery = "SELECT 1 FROM DUAL"
        }

        var result = try await conn.executeQuery(effectiveQuery)
        let executionTime = Date().timeIntervalSince(startTime)

        // OracleNIO may not populate column metadata for empty result sets.
        if result.columns.isEmpty && result.rows.isEmpty {
            if let table = Self.extractTableNameFromSelect(query) {
                let escapedTable = table.replacingOccurrences(of: "'", with: "''")
                let schema = effectiveSchemaEscaped(nil)
                let colSQL = """
                    SELECT COLUMN_NAME, DATA_TYPE FROM ALL_TAB_COLUMNS \
                    WHERE OWNER = '\(schema)' AND TABLE_NAME = '\(escapedTable)' \
                    ORDER BY COLUMN_ID
                    """
                if let colResult = try? await conn.executeQuery(colSQL) {
                    let colNames = colResult.rows.compactMap { $0.first ?? nil }
                    let colTypes = colResult.rows.map { ($0[safe: 1] ?? nil)?.lowercased() ?? "varchar2" }
                    if !colNames.isEmpty {
                        result = OracleQueryResult(
                            columns: colNames,
                            columnTypeNames: colTypes,
                            rows: [],
                            affectedRows: 0,
                            isTruncated: false
                        )
                    }
                }
            }
        }

        return PluginQueryResult(
            columns: result.columns,
            columnTypeNames: result.columnTypeNames,
            rows: result.rows,
            rowsAffected: result.affectedRows,
            executionTime: executionTime,
            isTruncated: result.isTruncated
        )
    }

    func fetchRowCount(query: String) async throws -> Int {
        let countQuery = "SELECT COUNT(*) FROM (\(query))"
        let result = try await execute(query: countQuery)
        guard let row = result.rows.first,
              let cell = row.first,
              let str = cell,
              let count = Int(str) else {
            return 0
        }
        return count
    }

    func fetchRows(query: String, offset: Int, limit: Int) async throws -> PluginQueryResult {
        var base = query.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix(";") {
            base = String(base.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        base = stripOracleOffsetFetch(from: base)
        let orderBy = hasTopLevelOrderBy(base) ? "" : " ORDER BY 1"
        let paginated = "\(base)\(orderBy) OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
        return try await execute(query: paginated)
    }

    // MARK: - Schema Operations

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        let escaped = effectiveSchemaEscaped(schema)
        let sql = """
            SELECT table_name, 'BASE TABLE' AS table_type FROM all_tables WHERE owner = '\(escaped)'
            UNION ALL
            SELECT view_name, 'VIEW' FROM all_views WHERE owner = '\(escaped)'
            ORDER BY 1
            """
        let result = try await execute(query: sql)
        return result.rows.compactMap { row -> PluginTableInfo? in
            guard let name = row[safe: 0] ?? nil else { return nil }
            let rawType = row[safe: 1] ?? nil
            let tableType = (rawType == "VIEW") ? "VIEW" : "TABLE"
            return PluginTableInfo(name: name, type: tableType)
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")
        let escaped = effectiveSchemaEscaped(schema)
        let sql = """
            SELECT
                c.COLUMN_NAME,
                c.DATA_TYPE,
                c.DATA_LENGTH,
                c.DATA_PRECISION,
                c.DATA_SCALE,
                c.NULLABLE,
                c.DATA_DEFAULT,
                CASE WHEN cc.COLUMN_NAME IS NOT NULL THEN 'Y' ELSE 'N' END AS IS_PK
            FROM ALL_TAB_COLUMNS c
            LEFT JOIN (
                SELECT acc.COLUMN_NAME
                FROM ALL_CONS_COLUMNS acc
                JOIN ALL_CONSTRAINTS ac ON acc.CONSTRAINT_NAME = ac.CONSTRAINT_NAME
                    AND acc.OWNER = ac.OWNER
                WHERE ac.CONSTRAINT_TYPE = 'P'
                    AND ac.OWNER = '\(escaped)'
                    AND ac.TABLE_NAME = '\(escapedTable)'
            ) cc ON c.COLUMN_NAME = cc.COLUMN_NAME
            WHERE c.OWNER = '\(escaped)'
              AND c.TABLE_NAME = '\(escapedTable)'
            ORDER BY c.COLUMN_ID
            """
        let result = try await execute(query: sql)
        return result.rows.compactMap { row -> PluginColumnInfo? in
            guard let name = row[safe: 0] ?? nil else { return nil }
            let dataType = (row[safe: 1] ?? nil)?.lowercased() ?? "varchar2"
            let dataLength = row[safe: 2] ?? nil
            let precision = row[safe: 3] ?? nil
            let scale = row[safe: 4] ?? nil
            let isNullable = (row[safe: 5] ?? nil) == "Y"
            let defaultValue = (row[safe: 6] ?? nil)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let isPk = (row[safe: 7] ?? nil) == "Y"

            let fullType = buildOracleFullType(dataType: dataType, dataLength: dataLength, precision: precision, scale: scale)

            return PluginColumnInfo(
                name: name,
                dataType: fullType,
                isNullable: isNullable,
                isPrimaryKey: isPk,
                defaultValue: defaultValue
            )
        }
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")
        let escaped = effectiveSchemaEscaped(schema)
        let sql = """
            SELECT i.INDEX_NAME, i.UNIQUENESS, ic.COLUMN_NAME,
                   CASE WHEN c.CONSTRAINT_TYPE = 'P' THEN 'Y' ELSE 'N' END AS IS_PK
            FROM ALL_INDEXES i
            JOIN ALL_IND_COLUMNS ic ON i.INDEX_NAME = ic.INDEX_NAME AND i.OWNER = ic.INDEX_OWNER
            LEFT JOIN ALL_CONSTRAINTS c ON i.INDEX_NAME = c.INDEX_NAME AND i.OWNER = c.OWNER
                AND c.CONSTRAINT_TYPE = 'P'
            WHERE i.TABLE_NAME = '\(escapedTable)'
              AND i.OWNER = '\(escaped)'
            ORDER BY i.INDEX_NAME, ic.COLUMN_POSITION
            """
        let result = try await execute(query: sql)
        var indexMap: [String: (unique: Bool, primary: Bool, columns: [String])] = [:]
        for row in result.rows {
            guard let idxName = row[safe: 0] ?? nil,
                  let colName = row[safe: 2] ?? nil else { continue }
            let isUnique = (row[safe: 1] ?? nil) == "UNIQUE"
            let isPrimary = (row[safe: 3] ?? nil) == "Y"
            if indexMap[idxName] == nil {
                indexMap[idxName] = (unique: isUnique, primary: isPrimary, columns: [])
            }
            indexMap[idxName]?.columns.append(colName)
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
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")
        let escaped = effectiveSchemaEscaped(schema)
        let sql = """
            SELECT
                ac.CONSTRAINT_NAME,
                acc.COLUMN_NAME,
                rc.TABLE_NAME AS REF_TABLE,
                rcc.COLUMN_NAME AS REF_COLUMN,
                ac.DELETE_RULE
            FROM ALL_CONSTRAINTS ac
            JOIN ALL_CONS_COLUMNS acc ON ac.CONSTRAINT_NAME = acc.CONSTRAINT_NAME
                AND ac.OWNER = acc.OWNER
            JOIN ALL_CONSTRAINTS rc ON ac.R_CONSTRAINT_NAME = rc.CONSTRAINT_NAME
                AND ac.R_OWNER = rc.OWNER
            JOIN ALL_CONS_COLUMNS rcc ON rc.CONSTRAINT_NAME = rcc.CONSTRAINT_NAME
                AND rc.OWNER = rcc.OWNER AND acc.POSITION = rcc.POSITION
            WHERE ac.CONSTRAINT_TYPE = 'R'
              AND ac.TABLE_NAME = '\(escapedTable)'
              AND ac.OWNER = '\(escaped)'
            ORDER BY ac.CONSTRAINT_NAME, acc.POSITION
            """
        let result = try await execute(query: sql)
        return result.rows.compactMap { row -> PluginForeignKeyInfo? in
            guard let constraintName = row[safe: 0] ?? nil,
                  let columnName = row[safe: 1] ?? nil,
                  let refTable = row[safe: 2] ?? nil,
                  let refColumn = row[safe: 3] ?? nil else { return nil }
            let deleteRule = (row[safe: 4] ?? nil) ?? "NO ACTION"
            return PluginForeignKeyInfo(
                name: constraintName,
                column: columnName,
                referencedTable: refTable,
                referencedColumn: refColumn,
                onDelete: deleteRule,
                onUpdate: "NO ACTION"
            )
        }
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
                c.DATA_DEFAULT,
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
            guard let tableName = row[safe: 0] ?? nil,
                  let name = row[safe: 1] ?? nil else { continue }
            let dataType = (row[safe: 2] ?? nil)?.lowercased() ?? "varchar2"
            let dataLength = row[safe: 3] ?? nil
            let precision = row[safe: 4] ?? nil
            let scale = row[safe: 5] ?? nil
            let isNullable = (row[safe: 6] ?? nil) == "Y"
            let defaultValue = (row[safe: 7] ?? nil)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let isPk = (row[safe: 8] ?? nil) == "Y"

            let fullType = buildOracleFullType(dataType: dataType, dataLength: dataLength, precision: precision, scale: scale)

            let col = PluginColumnInfo(
                name: name,
                dataType: fullType,
                isNullable: isNullable,
                isPrimaryKey: isPk,
                defaultValue: defaultValue
            )
            columnsByTable[tableName, default: []].append(col)
        }
        return columnsByTable
    }

    func fetchAllForeignKeys(schema: String?) async throws -> [String: [PluginForeignKeyInfo]] {
        let escaped = effectiveSchemaEscaped(schema)
        let sql = """
            SELECT
                ac.TABLE_NAME,
                ac.CONSTRAINT_NAME,
                acc.COLUMN_NAME,
                rc.TABLE_NAME AS REF_TABLE,
                rcc.COLUMN_NAME AS REF_COLUMN,
                ac.DELETE_RULE
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
            guard let tableName = row[safe: 0] ?? nil,
                  let constraintName = row[safe: 1] ?? nil,
                  let columnName = row[safe: 2] ?? nil,
                  let refTable = row[safe: 3] ?? nil,
                  let refColumn = row[safe: 4] ?? nil else { continue }
            let deleteRule = (row[safe: 5] ?? nil) ?? "NO ACTION"
            let fk = PluginForeignKeyInfo(
                name: constraintName,
                column: columnName,
                referencedTable: refTable,
                referencedColumn: refColumn,
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
            guard let name = row[safe: 0] ?? nil else { return nil }
            let tableCount = (row[safe: 1] ?? nil).flatMap { Int($0) } ?? 0
            let sizeBytes = (row[safe: 2] ?? nil).flatMap { Int64($0) }
            return PluginDatabaseMetadata(name: name, tableCount: tableCount, sizeBytes: sizeBytes)
        }
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")
        let escaped = effectiveSchemaEscaped(schema)
        let sql = "SELECT DBMS_METADATA.GET_DDL('TABLE', '\(escapedTable)', '\(escaped)') FROM DUAL"
        do {
            let result = try await execute(query: sql)
            if let row = result.rows.first, let ddl = row.first ?? nil {
                return ddl
            }
        } catch {
            Self.logger.debug("DBMS_METADATA failed, building DDL manually: \(error.localizedDescription)")
        }

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
        let sql = "SELECT TEXT FROM ALL_VIEWS WHERE VIEW_NAME = '\(escapedView)' AND OWNER = '\(escaped)'"
        let result = try await execute(query: sql)
        return result.rows.first?.first?.flatMap { $0 } ?? ""
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
            let rowCount = (row[safe: 0] ?? nil).flatMap { Int64($0) }
            let sizeBytes = (row[safe: 1] ?? nil).flatMap { Int64($0) } ?? 0
            let comment = row[safe: 2] ?? nil
            return PluginTableMetadata(
                tableName: table,
                dataSize: sizeBytes,
                totalSize: sizeBytes,
                rowCount: rowCount,
                comment: comment
            )
        }
        return PluginTableMetadata(tableName: table)
    }

    func fetchDatabases() async throws -> [String] {
        let sql = "SELECT USERNAME FROM ALL_USERS ORDER BY USERNAME"
        let result = try await execute(query: sql)
        return result.rows.compactMap { $0.first ?? nil }
    }

    func fetchSchemas() async throws -> [String] {
        let sql = "SELECT USERNAME FROM ALL_USERS ORDER BY USERNAME"
        let result = try await execute(query: sql)
        return result.rows.compactMap { $0.first ?? nil }
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
                let tableCount = (row[safe: 0] ?? nil).flatMap { Int($0) } ?? 0
                let sizeBytes = (row[safe: 1] ?? nil).flatMap { Int64($0) } ?? 0
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
        changes: [PluginRowChange],
        insertedRowData: [Int: [String?]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [String?])]? {
        var statements: [(statement: String, parameters: [String?])] = []

        for change in changes {
            switch change.type {
            case .insert:
                guard insertedRowIndices.contains(change.rowIndex) else { continue }
                if let values = insertedRowData[change.rowIndex] {
                    if let stmt = generateOracleInsert(table: table, columns: columns, values: values) {
                        statements.append(stmt)
                    }
                }
            case .update:
                if let stmt = generateOracleUpdate(table: table, columns: columns, change: change) {
                    statements.append(stmt)
                }
            case .delete:
                guard deletedRowIndices.contains(change.rowIndex) else { continue }
                if let stmt = generateOracleDelete(table: table, columns: columns, change: change) {
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
        table: String,
        columns: [String],
        values: [String?]
    ) -> (statement: String, parameters: [String?])? {
        var insertColumns: [String] = []
        var valuesSQL: [String] = []
        var parameters: [String?] = []

        for (index, value) in values.enumerated() {
            guard index < columns.count else { continue }
            insertColumns.append(escapeOracleIdentifier(columns[index]))
            if value == "__DEFAULT__" {
                valuesSQL.append("DEFAULT")
            } else {
                valuesSQL.append("?")
                parameters.append(value)
            }
        }

        guard !insertColumns.isEmpty else { return nil }

        let columnList = insertColumns.joined(separator: ", ")
        let valueList = valuesSQL.joined(separator: ", ")
        let sql = "INSERT INTO \(escapeOracleIdentifier(table)) (\(columnList)) VALUES (\(valueList))"
        return (statement: sql, parameters: parameters)
    }

    private func generateOracleUpdate(
        table: String,
        columns: [String],
        change: PluginRowChange
    ) -> (statement: String, parameters: [String?])? {
        guard !change.cellChanges.isEmpty, let originalRow = change.originalRow else { return nil }

        let escapedTable = escapeOracleIdentifier(table)
        var parameters: [String?] = []

        let setClauses = change.cellChanges.map { cellChange -> String in
            let col = escapeOracleIdentifier(cellChange.columnName)
            parameters.append(cellChange.newValue)
            return "\(col) = ?"
        }.joined(separator: ", ")

        var conditions: [String] = []
        for (index, columnName) in columns.enumerated() {
            guard index < originalRow.count else { continue }
            let col = escapeOracleIdentifier(columnName)
            if let value = originalRow[index] {
                parameters.append(value)
                conditions.append("\(col) = ?")
            } else {
                conditions.append("\(col) IS NULL")
            }
        }

        guard !conditions.isEmpty else { return nil }

        let whereClause = conditions.joined(separator: " AND ")
        let sql = "UPDATE \(escapedTable) SET \(setClauses) WHERE \(whereClause) AND ROWNUM = 1"
        return (statement: sql, parameters: parameters)
    }

    private func generateOracleDelete(
        table: String,
        columns: [String],
        change: PluginRowChange
    ) -> (statement: String, parameters: [String?])? {
        guard let originalRow = change.originalRow else { return nil }

        let escapedTable = escapeOracleIdentifier(table)
        var parameters: [String?] = []
        var conditions: [String] = []

        for (index, columnName) in columns.enumerated() {
            guard index < originalRow.count else { continue }
            let col = escapeOracleIdentifier(columnName)
            if let value = originalRow[index] {
                parameters.append(value)
                conditions.append("\(col) = ?")
            } else {
                conditions.append("\(col) IS NULL")
            }
        }

        guard !conditions.isEmpty else { return nil }

        let whereClause = conditions.joined(separator: " AND ")
        let sql = "DELETE FROM \(escapedTable) WHERE \(whereClause) AND ROWNUM = 1"
        return (statement: sql, parameters: parameters)
    }

    // MARK: - Schema Switching

    func switchSchema(to schema: String) async throws {
        let escaped = schema.replacingOccurrences(of: "\"", with: "\"\"")
        _ = try await execute(query: "ALTER SESSION SET CURRENT_SCHEMA = \"\(escaped)\"")
        _currentSchema = schema
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
        let quotedTable = oracleQuoteIdentifier(table)
        var query = "SELECT * FROM \(quotedTable)"
        let orderBy = oracleBuildOrderByClause(sortColumns: sortColumns, columns: columns)
            ?? "ORDER BY 1"
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
        let quotedTable = oracleQuoteIdentifier(table)
        var query = "SELECT * FROM \(quotedTable)"
        let whereClause = oracleBuildWhereClause(filters: filters, logicMode: logicMode)
        if !whereClause.isEmpty {
            query += " WHERE \(whereClause)"
        }
        let orderBy = oracleBuildOrderByClause(sortColumns: sortColumns, columns: columns)
            ?? "ORDER BY 1"
        query += " \(orderBy) OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
        return query
    }

    // MARK: - Query Building Helpers

    private func oracleQuoteIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func oracleBuildOrderByClause(
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String]
    ) -> String? {
        let parts = sortColumns.compactMap { sortCol -> String? in
            guard sortCol.columnIndex >= 0, sortCol.columnIndex < columns.count else { return nil }
            let columnName = columns[sortCol.columnIndex]
            let direction = sortCol.ascending ? "ASC" : "DESC"
            let quotedColumn = oracleQuoteIdentifier(columnName)
            return "\(quotedColumn) \(direction)"
        }
        guard !parts.isEmpty else { return nil }
        return "ORDER BY " + parts.joined(separator: ", ")
    }

    private func oracleEscapeForLike(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
            .replacingOccurrences(of: "'", with: "''")
    }

    private func oracleEscapeValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.caseInsensitiveCompare("NULL") == .orderedSame { return "NULL" }
        if Int(trimmed) != nil || Double(trimmed) != nil { return trimmed }
        return "'\(trimmed.replacingOccurrences(of: "'", with: "''"))'"
    }

    private func oracleBuildWhereClause(
        filters: [(column: String, op: String, value: String)],
        logicMode: String
    ) -> String {
        let conditions = filters.compactMap { filter -> String? in
            oracleBuildFilterCondition(column: filter.column, op: filter.op, value: filter.value)
        }
        guard !conditions.isEmpty else { return "" }
        let separator = logicMode == "and" ? " AND " : " OR "
        return conditions.joined(separator: separator)
    }

    private func oracleBuildFilterCondition(column: String, op: String, value: String) -> String? {
        let quoted = oracleQuoteIdentifier(column)
        switch op {
        case "=": return "\(quoted) = \(oracleEscapeValue(value))"
        case "!=": return "\(quoted) != \(oracleEscapeValue(value))"
        case ">": return "\(quoted) > \(oracleEscapeValue(value))"
        case ">=": return "\(quoted) >= \(oracleEscapeValue(value))"
        case "<": return "\(quoted) < \(oracleEscapeValue(value))"
        case "<=": return "\(quoted) <= \(oracleEscapeValue(value))"
        case "IS NULL": return "\(quoted) IS NULL"
        case "IS NOT NULL": return "\(quoted) IS NOT NULL"
        case "IS EMPTY": return "(\(quoted) IS NULL OR \(quoted) = '')"
        case "IS NOT EMPTY": return "(\(quoted) IS NOT NULL AND \(quoted) != '')"
        case "CONTAINS":
            let escaped = oracleEscapeForLike(value)
            return "\(quoted) LIKE '%\(escaped)%' ESCAPE '\\'"
        case "NOT CONTAINS":
            let escaped = oracleEscapeForLike(value)
            return "\(quoted) NOT LIKE '%\(escaped)%' ESCAPE '\\'"
        case "STARTS WITH":
            let escaped = oracleEscapeForLike(value)
            return "\(quoted) LIKE '\(escaped)%' ESCAPE '\\'"
        case "ENDS WITH":
            let escaped = oracleEscapeForLike(value)
            return "\(quoted) LIKE '%\(escaped)' ESCAPE '\\'"
        case "IN":
            let values = value.split(separator: ",")
                .map { oracleEscapeValue($0.trimmingCharacters(in: .whitespaces)) }
                .joined(separator: ", ")
            return values.isEmpty ? nil : "\(quoted) IN (\(values))"
        case "NOT IN":
            let values = value.split(separator: ",")
                .map { oracleEscapeValue($0.trimmingCharacters(in: .whitespaces)) }
                .joined(separator: ", ")
            return values.isEmpty ? nil : "\(quoted) NOT IN (\(values))"
        case "BETWEEN":
            let parts = value.split(separator: ",", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let v1 = oracleEscapeValue(parts[0].trimmingCharacters(in: .whitespaces))
            let v2 = oracleEscapeValue(parts[1].trimmingCharacters(in: .whitespaces))
            return "\(quoted) BETWEEN \(v1) AND \(v2)"
        case "REGEX":
            let escaped = value.replacingOccurrences(of: "'", with: "''")
            return "REGEXP_LIKE(\(quoted), '\(escaped)')"
        default: return nil
        }
    }

    // MARK: - Private Helpers

    private func buildOracleFullType(
        dataType: String,
        dataLength: String?,
        precision: String?,
        scale: String?
    ) -> String {
        let fixedTypes: Set<String> = [
            "date", "clob", "nclob", "blob", "bfile", "long", "long raw",
            "rowid", "urowid", "binary_float", "binary_double", "xmltype"
        ]
        var fullType = dataType
        if fixedTypes.contains(dataType) {
            // No suffix needed
        } else if dataType == "number" {
            if let p = precision, let pInt = Int(p) {
                if let s = scale, let sInt = Int(s), sInt > 0 {
                    fullType = "number(\(pInt),\(sInt))"
                } else {
                    fullType = "number(\(pInt))"
                }
            }
        } else if let len = dataLength, let lenInt = Int(len), lenInt > 0 {
            fullType = "\(dataType)(\(lenInt))"
        }
        return fullType
    }

    private func effectiveSchemaEscaped(_ schema: String?) -> String {
        let raw = schema ?? _currentSchema ?? config.username.uppercased()
        return raw.replacingOccurrences(of: "'", with: "''")
    }

    private func hasTopLevelOrderBy(_ query: String) -> Bool {
        let ns = query.uppercased() as NSString
        let len = ns.length
        guard len >= 8 else { return false }
        var depth = 0
        var i = len - 1
        while i >= 7 {
            let ch = ns.character(at: i)
            if ch == 0x29 { depth += 1 }
            else if ch == 0x28 { depth -= 1 }
            else if depth == 0 && ch == 0x59 {
                let start = i - 7
                if start >= 0 {
                    let candidate = ns.substring(with: NSRange(location: start, length: 8))
                    if candidate == "ORDER BY" { return true }
                }
            }
            i -= 1
        }
        return false
    }

    private func stripOracleOffsetFetch(from query: String) -> String {
        let ns = query.uppercased() as NSString
        let len = ns.length
        guard len >= 6 else { return query }
        var depth = 0
        var i = len - 1
        while i >= 5 {
            let ch = ns.character(at: i)
            if ch == 0x29 { depth += 1 }
            else if ch == 0x28 { depth -= 1 }
            else if depth == 0 && ch == 0x54 {
                let start = i - 5
                if start >= 0 {
                    let candidate = ns.substring(with: NSRange(location: start, length: 6))
                    if candidate == "OFFSET" {
                        return (query as NSString).substring(to: start)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
            i -= 1
        }
        return query
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
