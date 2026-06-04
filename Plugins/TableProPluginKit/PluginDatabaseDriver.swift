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

    // Connection
    func connect() async throws
    func disconnect()
    func ping() async throws

    // Queries
    func execute(query: String) async throws -> PluginQueryResult
    func executeUserQuery(query: String, rowCap: Int?, parameters: [PluginCellValue]?) async throws -> PluginQueryResult

    // Schema
    func fetchTables(schema: String?) async throws -> [PluginTableInfo]
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo]
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo]
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo]
    func fetchTableDDL(table: String, schema: String?) async throws -> String
    func fetchViewDefinition(view: String, schema: String?) async throws -> String
    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata
    func fetchDatabases() async throws -> [String]
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata

    // Schema navigation
    var supportsSchemas: Bool { get }
    func fetchSchemas() async throws -> [String]
    func switchSchema(to schema: String) async throws
    var currentSchema: String? { get }

    // Transactions
    var supportsTransactions: Bool { get }
    func beginTransaction() async throws
    func commitTransaction() async throws
    func rollbackTransaction() async throws

    // Execution control
    func cancelQuery() throws
    func applyQueryTimeout(_ seconds: Int) async throws
    var serverVersion: String? { get }
    var parameterStyle: ParameterStyle { get }

    var requiresBackslashEscapingInLiterals: Bool { get }

    // Batch operations
    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int?
    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]]
    func fetchAllForeignKeys(schema: String?) async throws -> [String: [PluginForeignKeyInfo]]
    func fetchAllDatabaseMetadata() async throws -> [PluginDatabaseMetadata]
    func fetchDependentTypes(table: String, schema: String?) async throws -> [(name: String, labels: [String])]
    func fetchDependentSequences(table: String, schema: String?) async throws -> [(name: String, ddl: String)]
    func createDatabaseFormSpec() async throws -> PluginCreateDatabaseFormSpec?
    func createDatabase(_ request: PluginCreateDatabaseRequest) async throws
    func dropDatabase(name: String) async throws
    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult

    // Query building (optional, for NoSQL plugins)
    func buildBrowseQuery(table: String, sortColumns: [(columnIndex: Int, ascending: Bool)], columns: [String], limit: Int, offset: Int) -> String?
    func buildFilteredQuery(table: String, filters: [(column: String, op: String, value: String)], logicMode: String, sortColumns: [(columnIndex: Int, ascending: Bool)], columns: [String], limit: Int, offset: Int) -> String?
    func buildBrowseQuery(table: String, schema: String?, sortColumns: [(columnIndex: Int, ascending: Bool)], columns: [String], limit: Int, offset: Int) -> String?
    func buildFilteredQuery(table: String, schema: String?, filters: [(column: String, op: String, value: String)], logicMode: String, sortColumns: [(columnIndex: Int, ascending: Bool)], columns: [String], limit: Int, offset: Int) -> String?
    // Filtered row count (optional, for NoSQL plugins; SQL plugins use COUNT(*) WHERE)
    func fetchFilteredRowCount(table: String, filters: [(column: String, op: String, value: String)], logicMode: String) async throws -> Int?
    // Statement generation (optional, for NoSQL plugins)
    func generateStatements(table: String, columns: [String], primaryKeyColumns: [String], changes: [PluginRowChange], insertedRowData: [Int: [PluginCellValue]], deletedRowIndices: Set<Int>, insertedRowIndices: Set<Int>) -> [(statement: String, parameters: [PluginCellValue])]?

    // Database switching (SQL Server USE, ClickHouse database switch, etc.)
    func switchDatabase(to database: String) async throws

    // DDL schema generation (optional, plugins return nil to use default fallback)
    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String?
    func generateModifyColumnSQL(table: String, oldColumn: PluginColumnDefinition, newColumn: PluginColumnDefinition) -> String?
    func generateDropColumnSQL(table: String, columnName: String) -> String?
    func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String?
    func generateDropIndexSQL(table: String, indexName: String) -> String?
    func generateAddForeignKeySQL(table: String, fk: PluginForeignKeyDefinition) -> String?
    func generateDropForeignKeySQL(table: String, constraintName: String) -> String?
    func generateModifyPrimaryKeySQL(table: String, oldColumns: [String], newColumns: [String], constraintName: String?) -> [String]?
    func generateMoveColumnSQL(table: String, column: PluginColumnDefinition, afterColumn: String?) -> String?
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

    // Maintenance operations (optional — return nil if not supported)
    func supportedMaintenanceOperations() -> [String]?
    func maintenanceStatements(operation: String, table: String?, schema: String?, options: [String: String]) -> [String]?

    // EXPLAIN query building (optional)
    func buildExplainQuery(_ sql: String) -> String?

    // Identifier quoting
    func quoteIdentifier(_ name: String) -> String

    // String escaping
    func escapeStringLiteral(_ value: String) -> String

    func createViewTemplate() -> String?
    func editViewFallbackTemplate(viewName: String) -> String?
    func castColumnToText(_ column: String) -> String

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

    var supportsSchemas: Bool { false }

    func fetchSchemas() async throws -> [String] { [] }

    func switchSchema(to schema: String) async throws {}

    var currentSchema: String? { nil }

    var supportsTransactions: Bool { true }

    func beginTransaction() async throws {
        _ = try await execute(query: "BEGIN")
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

    var requiresBackslashEscapingInLiterals: Bool { false }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? { nil }

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

    func dropDatabase(name: String) async throws {
        throw NSError(domain: "PluginDatabaseDriver", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "Drop database is not supported by this driver"])
    }

    func switchDatabase(to database: String) async throws {
        throw NSError(
            domain: "TableProPluginKit",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "This driver does not support database switching"]
        )
    }

    func buildBrowseQuery(table: String, sortColumns: [(columnIndex: Int, ascending: Bool)], columns: [String], limit: Int, offset: Int) -> String? { nil }
    func buildFilteredQuery(table: String, filters: [(column: String, op: String, value: String)], logicMode: String, sortColumns: [(columnIndex: Int, ascending: Bool)], columns: [String], limit: Int, offset: Int) -> String? { nil }
    func buildBrowseQuery(table: String, schema: String?, sortColumns: [(columnIndex: Int, ascending: Bool)], columns: [String], limit: Int, offset: Int) -> String? {
        buildBrowseQuery(table: table, sortColumns: sortColumns, columns: columns, limit: limit, offset: offset)
    }
    func buildFilteredQuery(table: String, schema: String?, filters: [(column: String, op: String, value: String)], logicMode: String, sortColumns: [(columnIndex: Int, ascending: Bool)], columns: [String], limit: Int, offset: Int) -> String? {
        buildFilteredQuery(table: table, filters: filters, logicMode: logicMode, sortColumns: sortColumns, columns: columns, limit: limit, offset: offset)
    }
    func fetchFilteredRowCount(table: String, filters: [(column: String, op: String, value: String)], logicMode: String) async throws -> Int? { nil }
    func generateStatements(table: String, columns: [String], primaryKeyColumns: [String], changes: [PluginRowChange], insertedRowData: [Int: [PluginCellValue]], deletedRowIndices: Set<Int>, insertedRowIndices: Set<Int>) -> [(statement: String, parameters: [PluginCellValue])]? { nil }

    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? { nil }
    func generateModifyColumnSQL(table: String, oldColumn: PluginColumnDefinition, newColumn: PluginColumnDefinition) -> String? { nil }
    func generateDropColumnSQL(table: String, columnName: String) -> String? { nil }
    func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String? { nil }
    func generateDropIndexSQL(table: String, indexName: String) -> String? { nil }
    func generateAddForeignKeySQL(table: String, fk: PluginForeignKeyDefinition) -> String? { nil }
    func generateDropForeignKeySQL(table: String, constraintName: String) -> String? { nil }
    func generateModifyPrimaryKeySQL(table: String, oldColumns: [String], newColumns: [String], constraintName: String?) -> [String]? { nil }
    func generateMoveColumnSQL(table: String, column: PluginColumnDefinition, afterColumn: String?) -> String? { nil }
    func generateCreateTableSQL(definition: PluginCreateTableDefinition) -> String? { nil }

    func generateColumnDefinitionSQL(column: PluginColumnDefinition) -> String? { nil }
    func generateIndexDefinitionSQL(index: PluginIndexDefinition, tableName: String?) -> String? { nil }
    func generateForeignKeyDefinitionSQL(fk: PluginForeignKeyDefinition) -> String? { nil }

    func truncateTableStatements(table: String, schema: String?, cascade: Bool) -> [String]? { nil }
    func dropObjectStatement(name: String, objectType: String, schema: String?, cascade: Bool) -> String? { nil }
    func foreignKeyDisableStatements() -> [String]? { nil }
    func foreignKeyEnableStatements() -> [String]? { nil }

    func supportedMaintenanceOperations() -> [String]? { nil }
    func maintenanceStatements(operation: String, table: String?, schema: String?, options: [String: String]) -> [String]? { nil }

    func buildExplainQuery(_ sql: String) -> String? { nil }

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

    public static func buildBrowseQuery(
        table: String,
        dialect: SQLDialectDescriptor,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String {
        let quotedTable = dialect.quoteIdentifier(table)
        return appendPagination(
            to: "SELECT * FROM \(quotedTable)",
            dialect: dialect,
            sortColumns: sortColumns,
            columns: columns,
            limit: limit,
            offset: offset
        )
    }

    public static func buildFilteredQuery(
        table: String,
        filters: [(column: String, op: String, value: String)],
        logicMode: String,
        dialect: SQLDialectDescriptor,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int,
        regexCondition: (_ quotedColumn: String, _ value: String) -> String?
    ) -> String {
        let quotedTable = dialect.quoteIdentifier(table)
        let whereClause = buildWhereClause(
            filters: filters,
            logicMode: logicMode,
            dialect: dialect,
            regexCondition: regexCondition
        )
        let baseQuery = whereClause.isEmpty
            ? "SELECT * FROM \(quotedTable)"
            : "SELECT * FROM \(quotedTable) WHERE \(whereClause)"

        return appendPagination(
            to: baseQuery,
            dialect: dialect,
            sortColumns: sortColumns,
            columns: columns,
            limit: limit,
            offset: offset
        )
    }

    public static func buildWhereClause(
        filters: [(column: String, op: String, value: String)],
        logicMode: String,
        dialect: SQLDialectDescriptor,
        regexCondition: (_ quotedColumn: String, _ value: String) -> String?
    ) -> String {
        let conditions = filters.compactMap { filter in
            buildFilterCondition(
                column: filter.column,
                op: filter.op,
                value: filter.value,
                dialect: dialect,
                regexCondition: regexCondition
            )
        }
        guard !conditions.isEmpty else { return "" }
        let separator = logicMode == "and" ? " AND " : " OR "
        return conditions.joined(separator: separator)
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
                escapeLikeWildcards: escapeForLike,
                likeEscapeClause: " ESCAPE '\\'",
                quoteLikePattern: false,
                normalizeNullEquality: false,
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
        dialect: SQLDialectDescriptor,
        regexCondition: (_ quotedColumn: String, _ value: String) -> String?
    ) -> String? {
        buildFilterCondition(
            column: column,
            op: op,
            value: value,
            quoteIdentifier: dialect.quoteIdentifier,
            escapeValue: { dialect.sqlLiteral(for: $0) },
            escapeLikeWildcards: dialect.escapeLikeWildcards,
            likeEscapeClause: dialect.likeEscapeClause,
            quoteLikePattern: true,
            normalizeNullEquality: true,
            regexCondition: regexCondition
        )
    }

    public static func buildFilterCondition(
        column: String,
        op: String,
        value: String,
        quoteIdentifier: (String) -> String,
        escapeValue: (String) -> String,
        regexCondition: (_ quotedColumn: String, _ value: String) -> String?
    ) -> String? {
        buildFilterCondition(
            column: column,
            op: op,
            value: value,
            quoteIdentifier: quoteIdentifier,
            escapeValue: escapeValue,
            escapeLikeWildcards: escapeForLike,
            likeEscapeClause: " ESCAPE '\\'",
            quoteLikePattern: false,
            normalizeNullEquality: false,
            regexCondition: regexCondition
        )
    }

    private static func buildFilterCondition(
        column: String,
        op: String,
        value: String,
        quoteIdentifier: (String) -> String,
        escapeValue: (String) -> String,
        escapeLikeWildcards: (String) -> String,
        likeEscapeClause: String,
        quoteLikePattern: Bool,
        normalizeNullEquality: Bool,
        regexCondition: (_ quotedColumn: String, _ value: String) -> String?
    ) -> String? {
        let quoted = quoteIdentifier(column)
        switch op {
        case "=":
            if normalizeNullEquality, isNullLiteral(value) { return "\(quoted) IS NULL" }
            return "\(quoted) = \(escapeValue(value))"
        case "!=":
            if normalizeNullEquality, isNullLiteral(value) { return "\(quoted) IS NOT NULL" }
            return "\(quoted) != \(escapeValue(value))"
        case ">": return "\(quoted) > \(escapeValue(value))"
        case ">=": return "\(quoted) >= \(escapeValue(value))"
        case "<": return "\(quoted) < \(escapeValue(value))"
        case "<=": return "\(quoted) <= \(escapeValue(value))"
        case "IS NULL": return "\(quoted) IS NULL"
        case "IS NOT NULL": return "\(quoted) IS NOT NULL"
        case "IS EMPTY": return "(\(quoted) IS NULL OR \(quoted) = '')"
        case "IS NOT EMPTY": return "(\(quoted) IS NOT NULL AND \(quoted) != '')"
        case "CONTAINS":
            return likeCondition(
                quoted,
                pattern: "%\(escapeLikeWildcards(value))%",
                negated: false,
                likeEscapeClause: likeEscapeClause,
                quotePattern: quoteLikePattern
            )
        case "NOT CONTAINS":
            return likeCondition(
                quoted,
                pattern: "%\(escapeLikeWildcards(value))%",
                negated: true,
                likeEscapeClause: likeEscapeClause,
                quotePattern: quoteLikePattern
            )
        case "STARTS WITH":
            return likeCondition(
                quoted,
                pattern: "\(escapeLikeWildcards(value))%",
                negated: false,
                likeEscapeClause: likeEscapeClause,
                quotePattern: quoteLikePattern
            )
        case "ENDS WITH":
            return likeCondition(
                quoted,
                pattern: "%\(escapeLikeWildcards(value))",
                negated: false,
                likeEscapeClause: likeEscapeClause,
                quotePattern: quoteLikePattern
            )
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

    private static func likeCondition(
        _ column: String,
        pattern: String,
        negated: Bool,
        likeEscapeClause: String,
        quotePattern: Bool
    ) -> String {
        let escapedPattern = quotePattern ? pattern.replacingOccurrences(of: "'", with: "''") : pattern
        let op = negated ? "NOT LIKE" : "LIKE"
        return "\(column) \(op) '\(escapedPattern)'\(likeEscapeClause)"
    }

    private static func appendPagination(
        to query: String,
        dialect: SQLDialectDescriptor,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String {
        let orderBy = buildOrderByClause(
            sortColumns: sortColumns,
            columns: columns,
            quoteIdentifier: dialect.quoteIdentifier
        )

        switch dialect.paginationStyle {
        case .limit:
            var result = query
            if let orderBy {
                result += " \(orderBy)"
            }
            result += " LIMIT \(limit)"
            if offset > 0 {
                result += " OFFSET \(offset)"
            }
            return result
        case .offsetFetch:
            let resolvedOrderBy = orderBy ?? dialect.offsetFetchOrderBy
            return "\(query) \(resolvedOrderBy) OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
        }
    }

    private static func isNullLiteral(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("NULL") == .orderedSame
    }
}

public enum PluginSQLStatementBuilder {
    public enum InsertDefaultStrategy {
        case omitColumn
        case useDefaultKeyword
    }

    public enum WhereColumnStrategy {
        case primaryKeyOrAll
        case allColumns
    }

    public static func generateStatements(
        table: String,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>,
        quoteIdentifier: (String) -> String,
        insertDefaultStrategy: InsertDefaultStrategy,
        includeInsertedColumn: (String) -> Bool = { _ in true },
        whereColumnStrategy: WhereColumnStrategy,
        collectDeletesLast: Bool = false,
        singleRowUpdatePrefixWhenNoPrimaryKey: String = "",
        singleRowDeletePrefixWhenNoPrimaryKey: String = "",
        updateWhereSuffix: String = "",
        deleteWhereSuffix: String = ""
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        var statements: [(statement: String, parameters: [PluginCellValue])] = []
        var deferredDeletes: [PluginRowChange] = []

        for change in changes {
            switch change.type {
            case .insert:
                guard insertedRowIndices.contains(change.rowIndex),
                      let values = insertedRowData[change.rowIndex],
                      let statement = buildInsert(
                        table: table,
                        columns: columns,
                        values: values,
                        quoteIdentifier: quoteIdentifier,
                        defaultStrategy: insertDefaultStrategy,
                        includeColumn: includeInsertedColumn
                      )
                else { continue }
                statements.append(statement)
            case .update:
                if let statement = buildUpdate(
                    table: table,
                    columns: columns,
                    primaryKeyColumns: primaryKeyColumns,
                    change: change,
                    quoteIdentifier: quoteIdentifier,
                    whereColumnStrategy: whereColumnStrategy,
                    singleRowPrefixWhenNoPrimaryKey: singleRowUpdatePrefixWhenNoPrimaryKey,
                    whereSuffix: updateWhereSuffix
                ) {
                    statements.append(statement)
                }
            case .delete:
                guard deletedRowIndices.contains(change.rowIndex) else { continue }
                if collectDeletesLast {
                    deferredDeletes.append(change)
                } else if let statement = buildDelete(
                    table: table,
                    columns: columns,
                    primaryKeyColumns: primaryKeyColumns,
                    change: change,
                    quoteIdentifier: quoteIdentifier,
                    whereColumnStrategy: whereColumnStrategy,
                    singleRowPrefixWhenNoPrimaryKey: singleRowDeletePrefixWhenNoPrimaryKey,
                    whereSuffix: deleteWhereSuffix
                ) {
                    statements.append(statement)
                }
            }
        }

        for change in deferredDeletes {
            if let statement = buildDelete(
                table: table,
                columns: columns,
                primaryKeyColumns: primaryKeyColumns,
                change: change,
                quoteIdentifier: quoteIdentifier,
                whereColumnStrategy: whereColumnStrategy,
                singleRowPrefixWhenNoPrimaryKey: singleRowDeletePrefixWhenNoPrimaryKey,
                whereSuffix: deleteWhereSuffix
            ) {
                statements.append(statement)
            }
        }

        return statements.isEmpty ? nil : statements
    }

    private static func buildInsert(
        table: String,
        columns: [String],
        values: [PluginCellValue],
        quoteIdentifier: (String) -> String,
        defaultStrategy: InsertDefaultStrategy,
        includeColumn: (String) -> Bool
    ) -> (statement: String, parameters: [PluginCellValue])? {
        var insertColumns: [String] = []
        var valueFragments: [String] = []
        var parameters: [PluginCellValue] = []

        for (index, value) in values.enumerated() {
            guard index < columns.count else { continue }
            let column = columns[index]

            if value.asText == "__DEFAULT__" {
                switch defaultStrategy {
                case .omitColumn:
                    continue
                case .useDefaultKeyword:
                    insertColumns.append(quoteIdentifier(column))
                    valueFragments.append("DEFAULT")
                    continue
                }
            }

            guard includeColumn(column) else { continue }
            insertColumns.append(quoteIdentifier(column))
            valueFragments.append("?")
            parameters.append(value)
        }

        guard !insertColumns.isEmpty else { return nil }

        let columnList = insertColumns.joined(separator: ", ")
        let valueList = valueFragments.joined(separator: ", ")
        let statement = "INSERT INTO \(quoteIdentifier(table)) (\(columnList)) VALUES (\(valueList))"
        return (statement: statement, parameters: parameters)
    }

    private static func buildUpdate(
        table: String,
        columns: [String],
        primaryKeyColumns: [String],
        change: PluginRowChange,
        quoteIdentifier: (String) -> String,
        whereColumnStrategy: WhereColumnStrategy,
        singleRowPrefixWhenNoPrimaryKey: String,
        whereSuffix: String
    ) -> (statement: String, parameters: [PluginCellValue])? {
        guard !change.cellChanges.isEmpty,
              let originalRow = change.originalRow
        else { return nil }

        var parameters: [PluginCellValue] = []
        let setClauses = change.cellChanges.map { cellChange -> String in
            parameters.append(cellChange.newValue)
            return "\(quoteIdentifier(cellChange.columnName)) = ?"
        }.joined(separator: ", ")

        guard let whereClause = buildWhereClause(
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            originalRow: originalRow,
            quoteIdentifier: quoteIdentifier,
            strategy: whereColumnStrategy,
            parameters: &parameters
        ) else { return nil }

        let prefix = primaryKeyColumns.isEmpty ? singleRowPrefixWhenNoPrimaryKey : ""
        let statement = "UPDATE \(prefix)\(quoteIdentifier(table)) SET \(setClauses) WHERE \(whereClause)\(whereSuffix)"
        return (statement: statement, parameters: parameters)
    }

    private static func buildDelete(
        table: String,
        columns: [String],
        primaryKeyColumns: [String],
        change: PluginRowChange,
        quoteIdentifier: (String) -> String,
        whereColumnStrategy: WhereColumnStrategy,
        singleRowPrefixWhenNoPrimaryKey: String,
        whereSuffix: String
    ) -> (statement: String, parameters: [PluginCellValue])? {
        guard let originalRow = change.originalRow else { return nil }

        var parameters: [PluginCellValue] = []
        guard let whereClause = buildWhereClause(
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            originalRow: originalRow,
            quoteIdentifier: quoteIdentifier,
            strategy: whereColumnStrategy,
            parameters: &parameters
        ) else { return nil }

        let prefix = primaryKeyColumns.isEmpty ? singleRowPrefixWhenNoPrimaryKey : ""
        let statement = "DELETE \(prefix)FROM \(quoteIdentifier(table)) WHERE \(whereClause)\(whereSuffix)"
        return (statement: statement, parameters: parameters)
    }

    private static func buildWhereClause(
        columns: [String],
        primaryKeyColumns: [String],
        originalRow: [PluginCellValue],
        quoteIdentifier: (String) -> String,
        strategy: WhereColumnStrategy,
        parameters: inout [PluginCellValue]
    ) -> String? {
        let whereColumns: [String]
        switch strategy {
        case .primaryKeyOrAll:
            whereColumns = primaryKeyColumns.isEmpty ? columns : primaryKeyColumns
        case .allColumns:
            whereColumns = columns
        }

        var conditions: [String] = []
        for column in whereColumns {
            guard let columnIndex = columns.firstIndex(of: column),
                  columnIndex < originalRow.count
            else { continue }

            let quotedColumn = quoteIdentifier(column)
            let value = originalRow[columnIndex]
            if value.isNull {
                conditions.append("\(quotedColumn) IS NULL")
            } else {
                parameters.append(value)
                conditions.append("\(quotedColumn) = ?")
            }
        }

        guard !conditions.isEmpty else { return nil }
        return conditions.joined(separator: " AND ")
    }
}
