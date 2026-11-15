import Foundation
import TableProPluginKit

nonisolated struct SQLImportStatement: Equatable, Sendable {
    let sql: String
    let parameters: [PluginCellValue]
    // By position, the type of the column each parameter is written to or compared with. Nil when none is known.
    let parameterTypeNames: [String?]?
}

// The statements a row import sends to one table, every value bound. What the host knows of its engine and session
// (placeholders, quoting, BIT columns, the table as statements spell it) comes in; the rest is keyed by type id.
nonisolated struct SQLImportStatements {
    let databaseTypeId: String
    let qualifiedTableName: String
    let parameterStyle: ParameterStyle
    let maxBindParameters: Int
    let maxRowsPerInsert: Int
    let rendersValuesAsLiterals: Bool
    private let columnTypeNames: [String: String]
    // BIT columns of a family that reads them as a number. Text bound to one is stored and compared as its bytes.
    private let numberBitColumns: Set<String>
    private let quoteIdentifier: (String) -> String
    private let rowUpdate: ((_ table: String, _ assignments: String, _ predicate: String) -> String?)?
    private let rowDelete: ((_ table: String, _ predicate: String?) -> String?)?

    init(
        databaseTypeId: String,
        qualifiedTableName: String,
        parameterStyle: ParameterStyle,
        quoteIdentifier: @escaping (String) -> String,
        columnTypeNames: [String: String] = [:],
        numberBitColumns: Set<String> = [],
        rowUpdateStatement: ((_ table: String, _ assignments: String, _ predicate: String) -> String?)? = nil,
        rowDeleteStatement: ((_ table: String, _ predicate: String?) -> String?)? = nil,
        maxBindParameters: Int? = nil,
        maxRowsPerInsert: Int? = nil,
        rendersValuesAsLiterals: Bool? = nil
    ) {
        self.databaseTypeId = databaseTypeId
        self.qualifiedTableName = qualifiedTableName
        self.parameterStyle = parameterStyle
        self.quoteIdentifier = quoteIdentifier
        self.columnTypeNames = columnTypeNames
        self.numberBitColumns = numberBitColumns
        self.rowUpdate = rowUpdateStatement
        self.rowDelete = rowDeleteStatement
        self.maxBindParameters = maxBindParameters ?? Self.maxBindParameters(forDatabaseTypeId: databaseTypeId)
        self.maxRowsPerInsert = maxRowsPerInsert
            ?? SQLMultiRowInsert.maximumRowsPerStatement(forDatabaseTypeId: databaseTypeId)
        self.rendersValuesAsLiterals = rendersValuesAsLiterals
            ?? SQLWriteBatchBudget.rendersValuesAsLiterals(databaseTypeId: databaseTypeId)
    }

    static func maxBindParameters(forDatabaseTypeId databaseTypeId: String) -> Int {
        switch databaseTypeId {
        case "SQLite", "libSQL", "Turso": 32_766
        case "SQL Server": 2_100
        case "Cloudflare D1": 100
        default: 65_535
        }
    }

    // MARK: - Statements

    // For statements built without the table's columns, the caller names the one Oracle needs.
    func allDefaultsInsertStatement(firstColumn: String?) -> SQLImportStatement? {
        AllDefaultsInsert.sql(
            into: qualifiedTableName, databaseTypeId: databaseTypeId, firstWritableColumn: firstColumn.map(quoteIdentifier)
        ).map { SQLImportStatement(sql: $0, parameters: [], parameterTypeNames: nil) }
    }

    func insertStatement(columns insertColumns: [String], values: [PluginCellValue]) -> SQLImportStatement? {
        guard !insertColumns.isEmpty, insertColumns.count == values.count else { return nil }

        var bindParameters = Bindings()
        let columnList = insertColumns.map(quoteIdentifier).joined(separator: ", ")
        let placeholders = zip(insertColumns, values).map { column, value in
            bind(value, toColumn: column, into: &bindParameters)
        }.joined(separator: ", ")

        return statement("INSERT INTO \(qualifiedTableName) (\(columnList)) VALUES (\(placeholders))", bindParameters)
    }

    func insertStatement(columns insertColumns: [String], rows: [[PluginCellValue]]) -> SQLImportStatement? {
        guard !insertColumns.isEmpty, !rows.isEmpty,
              rows.allSatisfy({ $0.count == insertColumns.count }) else { return nil }

        var bindParameters = Bindings()
        let columnList = insertColumns.map(quoteIdentifier).joined(separator: ", ")
        let rowTuples = rows.map { values -> String in
            let placeholders = zip(insertColumns, values).map { column, value in
                bind(value, toColumn: column, into: &bindParameters)
            }.joined(separator: ", ")
            return "(\(placeholders))"
        }.joined(separator: ", ")

        return statement("INSERT INTO \(qualifiedTableName) (\(columnList)) VALUES \(rowTuples)", bindParameters)
    }

    // The server compares, so its casting and collation decide a match, as they do for the UPDATE that follows.
    func keyMatchCountStatement(keyColumns: [String], keys: [[PluginCellValue]]) -> SQLImportStatement? {
        guard !keyColumns.isEmpty, !keys.isEmpty, keys.allSatisfy({ $0.count == keyColumns.count }) else { return nil }

        var bindParameters = Bindings()
        let selects = keys.enumerated().map { position, values -> String in
            let conditions = zip(keyColumns, values).map { column, value -> String in
                "\(quoteIdentifier(column)) = \(bind(value, toColumn: column, into: &bindParameters))"
            }.joined(separator: " AND ")
            return "SELECT \(position), COUNT(*) FROM \(qualifiedTableName) WHERE \(conditions)"
        }

        return statement(selects.joined(separator: " UNION ALL "), bindParameters)
    }

    func keyedUpdateStatement(
        columns setColumns: [String],
        values: [PluginCellValue],
        keyColumns: [String],
        keyValues: [PluginCellValue]
    ) -> SQLImportStatement? {
        guard !setColumns.isEmpty, setColumns.count == values.count,
              !keyColumns.isEmpty, keyColumns.count == keyValues.count else { return nil }

        var bindParameters = Bindings()
        func bound(_ column: String, _ value: PluginCellValue) -> String {
            "\(quoteIdentifier(column)) = \(bind(value, toColumn: column, into: &bindParameters))"
        }
        let assignments = zip(setColumns, values).map(bound).joined(separator: ", ")
        let conditions = zip(keyColumns, keyValues).map(bound).joined(separator: " AND ")
        let sql = rowUpdate?(qualifiedTableName, assignments, conditions)
            ?? "UPDATE \(qualifiedTableName) SET \(assignments) WHERE \(conditions)"

        return statement(sql, bindParameters)
    }

    func deleteAllRowsStatement() -> String {
        rowDelete?(qualifiedTableName, nil) ?? "DELETE FROM \(qualifiedTableName)"
    }

    // MARK: - Binding

    nonisolated struct Bindings {
        private(set) var values: [PluginCellValue] = []
        private(set) var typeNames: [String?] = []

        var count: Int { values.count }

        mutating func append(_ value: PluginCellValue, typeName: String?) {
            values.append(value)
            typeNames.append(typeName)
        }
    }

    func statement(_ sql: String, _ bindings: Bindings) -> SQLImportStatement {
        SQLImportStatement(
            sql: sql,
            parameters: bindings.values,
            parameterTypeNames: bindings.typeNames.contains { $0 != nil } ? bindings.typeNames : nil
        )
    }

    func placeholder(at index: Int) -> String {
        switch parameterStyle {
        case .dollar:
            return "$\(index + 1)"
        case .questionMark:
            return "?"
        }
    }

    func typeName(of column: String?) -> String? {
        column.flatMap { columnTypeNames[$0] }
    }

    // Blank text goes as '', which the server stores as 0: cast, strict mode refuses it as a truncated integer, and a
    // space bound as it is would be its byte, 32.
    func bind(_ value: PluginCellValue, toColumn column: String?, into parameters: inout Bindings) -> String {
        guard let column, numberBitColumns.contains(column), case .text(let text) = value else {
            parameters.append(value, typeName: typeName(of: column))
            return placeholder(at: parameters.count - 1)
        }
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            parameters.append(.text(""), typeName: typeName(of: column))
            return placeholder(at: parameters.count - 1)
        }
        // The value is the CAST's operand, not the column's.
        parameters.append(.text(Self.decimalBitText(text)), typeName: nil)
        return "CAST(\(placeholder(at: parameters.count - 1)) AS UNSIGNED)"
    }

    // b'101' and 0b101 are SQL, not values, and a boolean word is no number: cast as text, each is 0 or an error.
    static func decimalBitText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch PluginSQLLiteral.booleanSynonym(for: trimmed) {
        case .isTrue: return "1"
        case .isFalse: return "0"
        case nil: break
        @unknown default: break
        }
        switch trimmed.lowercased() {
        case "t": return "1"
        case "f": return "0"
        default: break
        }
        let digits: Substring
        if trimmed.count > 3, trimmed.hasPrefix("b'") || trimmed.hasPrefix("B'"), trimmed.hasSuffix("'") {
            digits = trimmed.dropFirst(2).dropLast()
        } else if trimmed.hasPrefix("0b") {
            digits = trimmed.dropFirst(2)
        } else {
            return text
        }
        return UInt64(digits, radix: 2).map { String($0) } ?? text
    }
}
