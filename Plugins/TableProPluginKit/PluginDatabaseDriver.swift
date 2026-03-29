import Foundation

public enum ParameterStyle: String, Sendable {
    case questionMark  // ?
    case dollar        // $1, $2
}

public struct PluginRowChange: Sendable {
    public enum ChangeType: Sendable {
        case insert
        case update
        case delete
    }

    public let rowIndex: Int
    public let type: ChangeType
    public let cellChanges: [(columnIndex: Int, columnName: String, oldValue: String?, newValue: String?)]
    public let originalRow: [String?]?

    public init(
        rowIndex: Int,
        type: ChangeType,
        cellChanges: [(columnIndex: Int, columnName: String, oldValue: String?, newValue: String?)],
        originalRow: [String?]?
    ) {
        self.rowIndex = rowIndex
        self.type = type
        self.cellChanges = cellChanges
        self.originalRow = originalRow
    }
}

public protocol PluginDatabaseDriver: AnyObject, Sendable {
    // Connection
    func connect() async throws
    func disconnect()
    func ping() async throws

    // Queries
    func execute(query: String) async throws -> PluginQueryResult
    func fetchRowCount(query: String) async throws -> Int
    func fetchRows(query: String, offset: Int, limit: Int) async throws -> PluginQueryResult

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

    // Batch operations
    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int?
    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]]
    func fetchAllForeignKeys(schema: String?) async throws -> [String: [PluginForeignKeyInfo]]
    func fetchAllDatabaseMetadata() async throws -> [PluginDatabaseMetadata]
    func fetchDependentTypes(table: String, schema: String?) async throws -> [(name: String, labels: [String])]
    func fetchDependentSequences(table: String, schema: String?) async throws -> [(name: String, ddl: String)]
    func createDatabase(name: String, charset: String, collation: String?) async throws
    func executeParameterized(query: String, parameters: [String?]) async throws -> PluginQueryResult

    // Query building (optional, for NoSQL plugins)
    func buildBrowseQuery(table: String, sortColumns: [(columnIndex: Int, ascending: Bool)], columns: [String], limit: Int, offset: Int) -> String?
    func buildFilteredQuery(table: String, filters: [(column: String, op: String, value: String)], logicMode: String, sortColumns: [(columnIndex: Int, ascending: Bool)], columns: [String], limit: Int, offset: Int) -> String?
    // Statement generation (optional, for NoSQL plugins)
    func generateStatements(table: String, columns: [String], changes: [PluginRowChange], insertedRowData: [Int: [String?]], deletedRowIndices: Set<Int>, insertedRowIndices: Set<Int>) -> [(statement: String, parameters: [String?])]?

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

    // Table operations (optional — return nil to use app-level fallback)
    func truncateTableStatements(table: String, schema: String?, cascade: Bool) -> [String]?
    func dropObjectStatement(name: String, objectType: String, schema: String?, cascade: Bool) -> String?
    func foreignKeyDisableStatements() -> [String]?
    func foreignKeyEnableStatements() -> [String]?

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
}

public extension PluginDatabaseDriver {
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

    func createDatabase(name: String, charset: String, collation: String?) async throws {
        throw NSError(domain: "PluginDatabaseDriver", code: -1, userInfo: [NSLocalizedDescriptionKey: "createDatabase not supported"])
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
    func generateStatements(table: String, columns: [String], changes: [PluginRowChange], insertedRowData: [Int: [String?]], deletedRowIndices: Set<Int>, insertedRowIndices: Set<Int>) -> [(statement: String, parameters: [String?])]? { nil }

    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? { nil }
    func generateModifyColumnSQL(table: String, oldColumn: PluginColumnDefinition, newColumn: PluginColumnDefinition) -> String? { nil }
    func generateDropColumnSQL(table: String, columnName: String) -> String? { nil }
    func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String? { nil }
    func generateDropIndexSQL(table: String, indexName: String) -> String? { nil }
    func generateAddForeignKeySQL(table: String, fk: PluginForeignKeyDefinition) -> String? { nil }
    func generateDropForeignKeySQL(table: String, constraintName: String) -> String? { nil }
    func generateModifyPrimaryKeySQL(table: String, oldColumns: [String], newColumns: [String], constraintName: String?) -> [String]? { nil }
    func generateMoveColumnSQL(table: String, column: PluginColumnDefinition, afterColumn: String?) -> String? { nil }

    func truncateTableStatements(table: String, schema: String?, cascade: Bool) -> [String]? { nil }
    func dropObjectStatement(name: String, objectType: String, schema: String?, cascade: Bool) -> String? { nil }
    func foreignKeyDisableStatements() -> [String]? { nil }
    func foreignKeyEnableStatements() -> [String]? { nil }

    func buildExplainQuery(_ sql: String) -> String? { nil }

    func createViewTemplate() -> String? { nil }
    func editViewFallbackTemplate(viewName: String) -> String? { nil }
    func castColumnToText(_ column: String) -> String { column }
    func allTablesMetadataSQL(schema: String?) -> String? { nil }
    func defaultExportQuery(table: String) -> String? { nil }

    func quoteIdentifier(_ name: String) -> String {
        let escaped = name.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    func escapeStringLiteral(_ value: String) -> String {
        var result = value
        result = result.replacingOccurrences(of: "'", with: "''")
        result = result.replacingOccurrences(of: "\0", with: "")
        return result
    }

    func executeParameterized(query: String, parameters: [String?]) async throws -> PluginQueryResult {
        guard !parameters.isEmpty else {
            return try await execute(query: query)
        }

        let sql: String
        switch parameterStyle {
        case .questionMark:
            sql = Self.substituteQuestionMarks(query: query, parameters: parameters)
        case .dollar:
            sql = Self.substituteDollarParams(query: query, parameters: parameters)
        }

        return try await execute(query: sql)
    }

    private static func substituteQuestionMarks(query: String, parameters: [String?]) -> String {
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
                if let value = parameters[paramIndex] {
                    sql.append(escapedParameterValue(value))
                } else {
                    sql.append("NULL")
                }
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

    private static func substituteDollarParams(query: String, parameters: [String?]) -> String {
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
                    if let value = parameters[paramNum - 1] {
                        sql.append(escapedParameterValue(value))
                    } else {
                        sql.append("NULL")
                    }
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

    /// Escape a parameter value for safe interpolation into SQL.
    /// Numeric values are unquoted; strings are single-quoted with proper escaping.
    private static func escapedParameterValue(_ value: String) -> String {
        // Numeric: don't quote
        if Int64(value) != nil || (Double(value) != nil && value.contains(".")) {
            return value
        }
        // String: escape and quote
        let escaped = value
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "''")
        return "'\(escaped)'"
    }

    func fetchRowCount(query: String) async throws -> Int {
        let result = try await execute(query: "SELECT COUNT(*) FROM (\(query)) _t")
        guard let firstRow = result.rows.first, let value = firstRow.first, let countStr = value else {
            return 0
        }
        return Int(countStr) ?? 0
    }

    func fetchRows(query: String, offset: Int, limit: Int) async throws -> PluginQueryResult {
        try await execute(query: "\(query) LIMIT \(limit) OFFSET \(offset)")
    }
}
