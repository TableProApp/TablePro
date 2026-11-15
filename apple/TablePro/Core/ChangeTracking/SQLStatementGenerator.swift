import Foundation
import os
import TableProPluginKit
import TableProSQLGrammar

struct ParameterizedStatement: @unchecked Sendable {
    let sql: String
    let parameters: [Any?]
    // By position, the type of the column each parameter is written to or compared with. Nil when none is known.
    var parameterTypeNames: [String?]?

    // What a driver needs to write each value for its column; everything else stays the host's default.
    var context: PluginStatementContext {
        var context = PluginStatementContext()
        context.parameterTypeNames = parameterTypeNames
        return context
    }
}

extension ParameterizedStatement {
    init(_ statement: SQLImportStatement) {
        self.init(
            sql: statement.sql,
            parameters: statement.parameters.map(\.asAny),
            parameterTypeNames: statement.parameterTypeNames
        )
    }
}

// The rows it should touch hold the server to a count; the changes it writes tell a written change from a dropped one.
struct AttributedStatement: @unchecked Sendable {
    let statement: ParameterizedStatement
    let kind: RowWriteKind
    let rowIDs: [RowID]
    let changeIDs: [UUID]
    var refusesSharedKey = false

    var rowCount: Int { rowIDs.count }
}

struct SQLStatementGenerator {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLStatementGenerator")

    let tableName: String
    // Nil for a grid edit, which keeps the unqualified name; set by a copy between databases, whose target is not the
    // database the driver is pointed at.
    let schemaName: String?
    let columns: [String]
    let primaryKeyColumns: [String]
    // Server-computed columns reject any written value, so every INSERT and UPDATE leaves them out.
    let generatedColumns: Set<String>
    let rowMatchPolicy: RowMatchPolicy
    let databaseType: DatabaseType
    let parameterStyle: ParameterStyle
    // Set only by a restore that writes a row back with the identity it had: PostgreSQL refuses an explicit value for a
    // `GENERATED ALWAYS` column unless the INSERT says so.
    let insertOverridesSystemValue: Bool
    // The import statements, and the binding every statement here goes through.
    let importStatements: SQLImportStatements
    private let quoteIdentifierFn: (String) -> String

    init(
        tableName: String,
        schemaName: String? = nil,
        columns: [String],
        primaryKeyColumns: [String],
        databaseType: DatabaseType,
        generatedColumns: Set<String> = [],
        rowMatchPolicy: RowMatchPolicy = .none,
        columnTypeNames: [String: String] = [:],
        parameterStyle: ParameterStyle? = nil,
        insertOverridesSystemValue: Bool = false,
        dialect: SQLDialectDescriptor? = nil,
        quoteIdentifier: ((String) -> String)? = nil,
        rowUpdateStatement: ((_ table: String, _ assignments: String, _ predicate: String) -> String?)? = nil,
        rowDeleteStatement: ((_ table: String, _ predicate: String?) -> String?)? = nil
    ) throws {
        let quote: (String) -> String
        if let quoteIdentifier {
            quote = quoteIdentifier
        } else {
            let resolvedDialect = try resolveSQLDialect(for: databaseType, explicit: dialect)
            quote = quoteIdentifierFromDialect(resolvedDialect, databaseType: databaseType)
        }
        let explicitSchema = SchemaQualifiedName.explicitSchema(schemaName, databaseType: databaseType)
        let style = parameterStyle ?? Self.defaultParameterStyle(for: databaseType)
        self.tableName = tableName
        self.schemaName = explicitSchema
        self.columns = columns
        self.primaryKeyColumns = primaryKeyColumns
        self.generatedColumns = generatedColumns
        self.rowMatchPolicy = rowMatchPolicy
        self.databaseType = databaseType
        self.parameterStyle = style
        self.insertOverridesSystemValue = insertOverridesSystemValue
        self.quoteIdentifierFn = quote
        self.importStatements = SQLImportStatements(
            databaseTypeId: databaseType.rawValue,
            qualifiedTableName: SchemaQualifiedName.render(
                name: tableName, schema: explicitSchema, databaseType: databaseType, quote: quote
            ),
            parameterStyle: style,
            quoteIdentifier: quote,
            columnTypeNames: columnTypeNames,
            numberBitColumns: Self.numberBitColumns(in: columnTypeNames, databaseType: databaseType),
            rowUpdateStatement: rowUpdateStatement,
            rowDeleteStatement: rowDeleteStatement
        )
    }

    // The table as every statement spells it.
    var qualifiedTableName: String {
        importStatements.qualifiedTableName
    }

    private static func defaultParameterStyle(for databaseType: DatabaseType) -> ParameterStyle {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?.parameterStyle ?? .questionMark
    }

    // MARK: - Public API

    func generateStatements(
        from changes: [RowChange],
        insertedRowData: [RowID: [PluginCellValue]],
        deletedRowIDs: Set<RowID>,
        insertedRowIDs: Set<RowID>
    ) -> [ParameterizedStatement] {
        generateAttributedStatements(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIDs: deletedRowIDs,
            insertedRowIDs: insertedRowIDs
        ).map(\.statement)
    }

    // In edit order, since a row deleted to free a unique value must go before the row that takes it. Only a
    // consecutive run of deletes batches.
    func generateAttributedStatements(
        from changes: [RowChange],
        insertedRowData: [RowID: [PluginCellValue]],
        deletedRowIDs: Set<RowID>,
        insertedRowIDs: Set<RowID>
    ) -> [AttributedStatement] {
        var statements: [AttributedStatement] = []
        var deleteRun: [RowChange] = []

        func flushDeleteRun() {
            guard !deleteRun.isEmpty else { return }
            statements.append(contentsOf: generateDeleteStatements(for: deleteRun))
            deleteRun.removeAll(keepingCapacity: true)
        }

        for change in changes.sorted(by: { $0.sequence < $1.sequence }) {
            switch change.type {
            case .update:
                flushDeleteRun()
                if let stmt = generateUpdateSQL(for: change) {
                    statements.append(AttributedStatement(
                        statement: stmt, kind: .update, rowIDs: [change.rowID], changeIDs: [change.id],
                        refusesSharedKey: matchesEitherWay(change)
                    ))
                }
            case .insert:
                // SAFETY: Verify the row is still marked as inserted
                guard insertedRowIDs.contains(change.rowID) else { continue }
                flushDeleteRun()
                if let stmt = generateInsertSQL(for: change, insertedRowData: insertedRowData) {
                    statements.append(AttributedStatement(
                        statement: stmt, kind: .insert, rowIDs: [change.rowID], changeIDs: [change.id]
                    ))
                }
            case .delete:
                // SAFETY: Verify the row is still marked as deleted
                guard deletedRowIDs.contains(change.rowID) else { continue }
                deleteRun.append(change)
            }
        }
        flushDeleteRun()

        return statements
    }

    private static func numberBitColumns(in typeNames: [String: String], databaseType: DatabaseType) -> Set<String> {
        let family = SQLTypeFamily.of(databaseType)
        guard family.readsBitsAsDecimal else { return [] }
        let bitColumns = typeNames.filter { _, typeName in
            if case .bitString = SQLTypeParser.parse(typeName, family: family).kind { return true }
            return false
        }
        return Set(bitColumns.keys)
    }

    private typealias Bindings = SQLImportStatements.Bindings

    private func statement(_ sql: String, _ bindings: Bindings) -> ParameterizedStatement {
        ParameterizedStatement(importStatements.statement(sql, bindings))
    }

    private func bind(_ value: PluginCellValue, toColumn column: String?, into parameters: inout Bindings) -> String {
        importStatements.bind(value, toColumn: column, into: &parameters)
    }

    static func decimalBitText(_ text: String) -> String {
        SQLImportStatements.decimalBitText(text)
    }

    // MARK: - INSERT Generation

    private func generateInsertSQL(for change: RowChange, insertedRowData: [RowID: [PluginCellValue]])
        -> ParameterizedStatement?
    {
        if let values = insertedRowData[change.rowID] {
            return generateInsertSQLFromStoredData(values: values, expressionColumns: change.expressionColumns)
        }
        return generateInsertSQLFromCellChanges(for: change)
    }

    // A cell is written as SQL only when its change says so. Text that merely reads like a function is bound.
    private func generateInsertSQLFromStoredData(values: [PluginCellValue], expressionColumns: Set<Int>)
        -> ParameterizedStatement?
    {
        var nonDefaultColumns: [String] = []
        var placeholderParts: [String] = []
        var bindParameters = Bindings()

        for (index, value) in values.enumerated() {
            // Left out rather than written as DEFAULT, which SQLite does not take in VALUES.
            if value.isColumnDefault(isExpression: expressionColumns.contains(index)) { continue }

            guard index < columns.count else { continue }
            let columnName = columns[index]
            guard !generatedColumns.contains(columnName) else { continue }

            nonDefaultColumns.append(quoteIdentifierFn(columnName))

            switch value {
            case .text(let expression) where expressionColumns.contains(index):
                placeholderParts.append(expression)
            default:
                placeholderParts.append(bind(value, toColumn: columnName, into: &bindParameters))
            }
        }

        guard !nonDefaultColumns.isEmpty else { return allDefaultsInsertStatement() }

        let columnList = nonDefaultColumns.joined(separator: ", ")
        let placeholders = placeholderParts.joined(separator: ", ")

        let override = insertOverridesSystemValue ? " OVERRIDING SYSTEM VALUE" : ""
        let sql =
            "INSERT INTO \(qualifiedTableName) (\(columnList))\(override) VALUES (\(placeholders))"

        return statement(sql, bindParameters)
    }

    private func allDefaultsInsertStatement() -> ParameterizedStatement? {
        allDefaultsInsertStatement(firstColumn: columns.first { !generatedColumns.contains($0) })
    }

    func allDefaultsInsertStatement(firstColumn: String?) -> ParameterizedStatement? {
        importStatements.allDefaultsInsertStatement(firstColumn: firstColumn).map(ParameterizedStatement.init)
    }

    func insertStatement(columns insertColumns: [String], values: [PluginCellValue]) -> ParameterizedStatement? {
        importStatements.insertStatement(columns: insertColumns, values: values).map(ParameterizedStatement.init)
    }

    func insertStatement(columns insertColumns: [String], rows: [[PluginCellValue]]) -> ParameterizedStatement? {
        importStatements.insertStatement(columns: insertColumns, rows: rows).map(ParameterizedStatement.init)
    }

    func keyMatchCountStatement(keyColumns: [String], keys: [[PluginCellValue]]) -> ParameterizedStatement? {
        importStatements.keyMatchCountStatement(keyColumns: keyColumns, keys: keys).map(ParameterizedStatement.init)
    }

    func keyedUpdateStatement(
        columns setColumns: [String],
        values: [PluginCellValue],
        keyColumns: [String],
        keyValues: [PluginCellValue]
    ) -> ParameterizedStatement? {
        importStatements.keyedUpdateStatement(
            columns: setColumns, values: values, keyColumns: keyColumns, keyValues: keyValues
        ).map(ParameterizedStatement.init)
    }

    var maxBindParameters: Int {
        importStatements.maxBindParameters
    }

    func deleteAllRowsStatement() -> String {
        importStatements.deleteAllRowsStatement()
    }

    private func generateInsertSQLFromCellChanges(for change: RowChange) -> ParameterizedStatement?
    {
        guard !change.cellChanges.isEmpty else { return nil }

        let nonDefaultChanges = change.cellChanges.filter {
            !$0.newValue.isColumnDefault(isExpression: $0.newIsExpression) && !generatedColumns.contains($0.columnName)
        }

        guard !nonDefaultChanges.isEmpty else { return nil }

        let columnNames = nonDefaultChanges.map {
            quoteIdentifierFn($0.columnName)
        }.joined(separator: ", ")

        var parameters = Bindings()
        let placeholders = nonDefaultChanges.map { cellChange -> String in
            switch cellChange.newValue {
            case .text(let expression) where cellChange.newIsExpression:
                return expression
            default:
                return bind(cellChange.newValue, toColumn: cellChange.columnName, into: &parameters)
            }
        }.joined(separator: ", ")

        let sql =
            "INSERT INTO \(qualifiedTableName) (\(columnNames)) VALUES (\(placeholders))"

        return statement(sql, parameters)
    }

    // MARK: - UPDATE Generation

    func generateUpdateSQL(for change: RowChange) -> ParameterizedStatement? {
        guard !change.cellChanges.isEmpty else { return nil }

        let writableChanges = change.cellChanges.filter { !generatedColumns.contains($0.columnName) }
        guard !writableChanges.isEmpty else { return nil }

        var parameters = Bindings()
        let setClauses = writableChanges.map { cellChange -> String in
            switch cellChange.newValue {
            case .text(let expression) where cellChange.newIsExpression:
                return "\(quoteIdentifierFn(cellChange.columnName)) = \(expression)"
            default:
                let bound = bind(cellChange.newValue, toColumn: cellChange.columnName, into: &parameters)
                return "\(quoteIdentifierFn(cellChange.columnName)) = \(bound)"
            }
        }.joined(separator: ", ")

        if !primaryKeyColumns.isEmpty {
            var terms: [RowMatchTerm] = []

            for pkColumn in primaryKeyColumns {
                guard let pkColumnIndex = columns.firstIndex(of: pkColumn) else { return nil }

                var pkValue: PluginCellValue?
                if let originalRow = change.originalRow, pkColumnIndex < originalRow.count {
                    pkValue = originalRow[pkColumnIndex]
                } else if let pkChange = change.cellChanges.first(where: { $0.columnName == pkColumn }) {
                    pkValue = pkChange.oldValue
                }

                guard let pkValue, !pkValue.isNull else {
                    Self.logger.warning(
                        "Skipping UPDATE for table '\(self.tableName)' - cannot determine value for PK column '\(pkColumn)'"
                    )
                    return nil
                }

                terms.append(RowMatchTerm(matched: quoteIdentifierFn(pkColumn), value: pkValue, column: pkColumn))
            }

            guard !terms.isEmpty else { return nil }

            let whereClause = rowCondition(terms, parameters: &parameters)
            let sql =
                "UPDATE \(qualifiedTableName) SET \(setClauses) WHERE \(whereClause)"
            return statement(sql, parameters)
        } else {
            guard let originalRow = change.originalRow else {
                Self.logger.warning(
                    "Skipping UPDATE for table '\(self.tableName)' - no primary key and no original row data"
                )
                return nil
            }

            var terms: [RowMatchTerm] = []
            for (index, columnName) in columns.enumerated() {
                guard index < originalRow.count,
                      !rowMatchPolicy.excludedColumns.contains(columnName) else { continue }
                let value = originalRow[index]
                let matched = rowMatchPolicy.matchExpression(
                    for: columnName, quoted: quoteIdentifierFn(columnName), value: value, databaseType: databaseType
                )
                // Spelled out: a bare `nil` here is PluginCellValue's own nil literal, `.null`, which binds rather than reads IS NULL.
                terms.append(RowMatchTerm(
                    matched: matched,
                    value: value.isNull ? Optional<PluginCellValue>.none : value,
                    column: plainlyMatchedColumn(columnName)
                ))
            }

            guard !terms.isEmpty else { return nil }

            let whereClause = rowCondition(terms, parameters: &parameters)
            let sql =
                "UPDATE \(qualifiedTableName) SET \(setClauses) WHERE \(whereClause)"

            return statement(sql, parameters)
        }
    }

    private struct RowMatchTerm {
        let matched: String
        let value: PluginCellValue?
        // Nil when `matched` is not the bare column, so its value is bound as it is.
        let column: String?
    }

    private func plainlyMatchedColumn(_ column: String) -> String? {
        rowMatchPolicy.textColumns.contains(column) ? nil : column
    }

    // SQLite keeps the number 5 and the text '5' apart in a column with no affinity, and the grid read either as `5`,
    // so a number the grid read matches both, held by a CAST to text so a REAL 5.0 is not matched too. When both rows
    // exist the statement itself refuses them.
    private func rowCondition(_ terms: [RowMatchTerm], parameters: inout Bindings) -> String {
        let clause = conditions(terms, parameters: &parameters)
        guard terms.contains(where: { matchesEitherWay($0.value) }) else { return clause }
        let again = conditions(terms, parameters: &parameters)
        return "\(clause) AND (SELECT COUNT(*) FROM \(qualifiedTableName) WHERE \(again)) = 1"
    }

    private func conditions(_ terms: [RowMatchTerm], parameters: inout Bindings) -> String {
        terms.map { term in
            guard let value = term.value else { return "\(term.matched) IS NULL" }
            guard matchesEitherWay(value), case .text(let text) = value else {
                return "\(term.matched) = \(bind(value, toColumn: term.column, into: &parameters))"
            }
            parameters.append(value, typeName: importStatements.typeName(of: term.column))
            let bound = importStatements.placeholder(at: parameters.count - 1)
            // Compared with the column's text, not the column.
            parameters.append(value, typeName: nil)
            let read = importStatements.placeholder(at: parameters.count - 1)
            return "(\(term.matched) IN (\(text), \(bound)) AND CAST(\(term.matched) AS TEXT) = \(read))"
        }.joined(separator: " AND ")
    }

    private func matchesEitherWay(_ value: PluginCellValue?) -> Bool {
        guard SQLTypeFamily.of(databaseType) == .sqlite, case .text(let text)? = value else { return false }
        return SQLiteNumberText.isStoredSpelling(text)
    }

    private func matchesEitherWay(_ change: RowChange) -> Bool {
        let matched = primaryKeyColumns.isEmpty
            ? columns.filter { !rowMatchPolicy.excludedColumns.contains($0) }
            : primaryKeyColumns
        return matched.contains { column in
            if let originalRow = change.originalRow, let index = columns.firstIndex(of: column), index < originalRow.count {
                return matchesEitherWay(originalRow[index])
            }
            return matchesEitherWay(change.cellChanges.first { $0.columnName == column }?.oldValue)
        }
    }

    // MARK: - DELETE Generation

    private struct DeleteColumnMatch {
        let column: String
        let boundValue: PluginCellValue?
    }

    private func generateDeleteStatements(for changes: [RowChange]) -> [AttributedStatement] {
        let rowMatches = changes.compactMap { change in
            deleteRowMatches(for: change).map { (rowID: change.rowID, changeID: change.id, matches: $0) }
        }
        guard !rowMatches.isEmpty else { return [] }

        var statements: [AttributedStatement] = []
        var chunk: [(rowID: RowID, changeID: UUID, matches: [DeleteColumnMatch])] = []
        var chunkParameterCount = 0

        func flush() {
            statements.append(
                AttributedStatement(
                    statement: deleteStatement(for: chunk.map(\.matches)),
                    kind: .delete,
                    rowIDs: chunk.map(\.rowID),
                    changeIDs: chunk.map(\.changeID),
                    refusesSharedKey: chunk.contains { $0.matches.contains { matchesEitherWay($0.boundValue) } }
                )
            )
        }

        let matchesOneRowPerStatement = primaryKeyColumns.isEmpty && !rowMatchPolicy.excludedColumns.isEmpty
        for row in rowMatches {
            let boundCount = row.matches.count(where: { $0.boundValue != nil })
            // An either-way term binds its value twice, and the row's guard repeats every term.
            let eitherWayCount = row.matches.count(where: { matchesEitherWay($0.boundValue) })
            let rowParameterCount = eitherWayCount > 0 ? (boundCount + eitherWayCount) * 2 : boundCount
            if !chunk.isEmpty,
               matchesOneRowPerStatement || chunkParameterCount + rowParameterCount > maxBindParameters {
                flush()
                chunk = []
                chunkParameterCount = 0
            }
            chunk.append(row)
            chunkParameterCount += rowParameterCount
        }

        if !chunk.isEmpty {
            flush()
        }

        return statements
    }

    private func deleteRowMatches(for change: RowChange) -> [DeleteColumnMatch]? {
        guard let originalRow = change.originalRow else { return nil }

        if !primaryKeyColumns.isEmpty {
            var matches: [DeleteColumnMatch] = []
            for pkColumn in primaryKeyColumns {
                guard let pkIndex = columns.firstIndex(of: pkColumn), pkIndex < originalRow.count else {
                    return nil
                }
                let value = originalRow[pkIndex]
                guard !value.isNull else { return nil }
                matches.append(DeleteColumnMatch(column: pkColumn, boundValue: value))
            }
            return matches.isEmpty ? nil : matches
        }

        var matches: [DeleteColumnMatch] = []
        for (index, columnName) in columns.enumerated() {
            guard index < originalRow.count,
                  !rowMatchPolicy.excludedColumns.contains(columnName) else { continue }
            let value = originalRow[index]
            if value.isNull {
                matches.append(DeleteColumnMatch(column: columnName, boundValue: nil))
            } else {
                matches.append(DeleteColumnMatch(column: columnName, boundValue: value))
            }
        }
        return matches.isEmpty ? nil : matches
    }

    private func deleteStatement(for rows: [[DeleteColumnMatch]]) -> ParameterizedStatement {
        var parameters = Bindings()
        let rowClauses = rows.map { matches -> String in
            let terms = matches.map { match in
                RowMatchTerm(
                    matched: rowMatchPolicy.matchExpression(
                        for: match.column,
                        quoted: quoteIdentifierFn(match.column),
                        value: match.boundValue ?? .null,
                        databaseType: databaseType
                    ),
                    value: match.boundValue,
                    column: plainlyMatchedColumn(match.column)
                )
            }
            let joined = rowCondition(terms, parameters: &parameters)
            let isCompound = matches.count > 1 || terms.contains { matchesEitherWay($0.value) }
            return isCompound ? "(\(joined))" : joined
        }

        let whereClause = rowClauses.joined(separator: " OR ")
        let sql = "DELETE FROM \(qualifiedTableName) WHERE \(whereClause)"
        return statement(sql, parameters)
    }
}
