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
            sql = Self.substituteQuestionMarks(query: query, parameters: parameters)
        case .dollar:
            sql = Self.substituteDollarParams(query: query, parameters: parameters)
        }

        return try await execute(query: sql)
    }

    private static func substituteQuestionMarks(query: String, parameters: [PluginCellValue]) -> String {
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

    private static func substituteDollarParams(query: String, parameters: [PluginCellValue]) -> String {
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

    static func sqlLiteral(for value: PluginCellValue) -> String {
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

    static func escapedParameterValue(_ value: String) -> String {
        if isNumericLiteral(value) {
            return value
        }
        var escaped = ""
        escaped.reserveCapacity(value.count + 2)
        escaped.append("'")
        for char in value {
            switch char {
            case "'":
                escaped.append("''")
            case "\0":
                continue
            case "\\":
                escaped.append("\\\\")
            case "\n":
                escaped.append("\\n")
            case "\r":
                escaped.append("\\r")
            case "\t":
                escaped.append("\\t")
            case "\u{1A}":
                escaped.append("\\Z")
            default:
                escaped.append(char)
            }
        }
        escaped.append("'")
        return escaped
    }

    static func isNumericLiteral(_ value: String) -> Bool {
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
