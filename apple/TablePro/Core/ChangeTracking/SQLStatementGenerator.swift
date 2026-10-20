//
//  SQLStatementGenerator.swift
//  TablePro
//
//  Generates parameterized SQL statements (INSERT, UPDATE, DELETE) from tracked changes.
//  Uses prepared statements instead of string escaping to prevent SQL injection.
//

import Foundation
import os
import TableProPluginKit
import TableProSQLGrammar

/// A parameterized SQL statement with placeholders and bound values
struct ParameterizedStatement: @unchecked Sendable {
    let sql: String
    let parameters: [Any?]
}

/// A statement plus the rows it is meant to touch, so a caller can hold the server to that count
/// and tell a change that became a statement from one that did not.
struct AttributedStatement: @unchecked Sendable {
    let statement: ParameterizedStatement
    let kind: RowWriteKind
    let rowIDs: [RowID]
    var refusesSharedKey = false

    var rowCount: Int { rowIDs.count }
}

/// Generates SQL statements from data changes
struct SQLStatementGenerator {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLStatementGenerator")

    let tableName: String
    /// Written into every statement when set, so a generator can address a table outside whatever
    /// schema the connection happens to be on. A grid edit leaves it nil and keeps the unqualified
    /// name it has always produced; a copy between two databases sets it, because the table it
    /// writes is not the one the driver is pointed at.
    let schemaName: String?
    let columns: [String]
    let primaryKeyColumns: [String]
    /// Server-computed columns. They reject any written value, so they are
    /// dropped from every INSERT and UPDATE this generator produces.
    let generatedColumns: Set<String>
    let rowMatchPolicy: RowMatchPolicy
    let databaseType: DatabaseType
    let parameterStyle: ParameterStyle
    /// Set only by a restore that writes a row back with the identity it had: PostgreSQL refuses an explicit value
    /// for a `GENERATED ALWAYS` column unless the INSERT says so.
    let insertOverridesSystemValue: Bool
    private let quoteIdentifierFn: (String) -> String

    init(
        tableName: String,
        schemaName: String? = nil,
        columns: [String],
        primaryKeyColumns: [String],
        databaseType: DatabaseType,
        generatedColumns: Set<String> = [],
        rowMatchPolicy: RowMatchPolicy = .none,
        parameterStyle: ParameterStyle? = nil,
        insertOverridesSystemValue: Bool = false,
        dialect: SQLDialectDescriptor? = nil,
        quoteIdentifier: ((String) -> String)? = nil
    ) throws {
        self.tableName = tableName
        self.schemaName = SchemaQualifiedName.explicitSchema(schemaName, databaseType: databaseType)
        self.columns = columns
        self.primaryKeyColumns = primaryKeyColumns
        self.generatedColumns = generatedColumns
        self.rowMatchPolicy = rowMatchPolicy
        self.databaseType = databaseType
        self.parameterStyle = parameterStyle ?? Self.defaultParameterStyle(for: databaseType)
        self.insertOverridesSystemValue = insertOverridesSystemValue
        if let quoteIdentifier {
            self.quoteIdentifierFn = quoteIdentifier
        } else {
            let resolvedDialect = try resolveSQLDialect(for: databaseType, explicit: dialect)
            self.quoteIdentifierFn = quoteIdentifierFromDialect(resolvedDialect)
        }
    }

    /// The table as every statement spells it.
    var qualifiedTableName: String {
        SchemaQualifiedName.render(
            name: tableName, schema: schemaName, databaseType: databaseType, quote: quoteIdentifierFn
        )
    }

    private static func defaultParameterStyle(for databaseType: DatabaseType) -> ParameterStyle {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?.parameterStyle ?? .questionMark
    }

    // MARK: - Public API

    /// Generate all parameterized SQL statements from changes
    /// - Parameters:
    ///   - changes: Array of row changes to process
    ///   - insertedRowData: Lazy storage for inserted row values
    ///   - deletedRowIDs: Rows still marked as deleted
    ///   - insertedRowIDs: Rows still marked as inserted
    /// - Returns: Array of parameterized SQL statements
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

    /// The same statements, each carrying how many rows it is meant to touch.
    ///
    /// Emitted in the order the user made the changes, because that order can be load-bearing: a
    /// row deleted to free a unique value, and a new row taking that value, only work if the
    /// DELETE runs first. Grouping every INSERT ahead of every DELETE, which is what this used to
    /// do, turned that save into a constraint violation and rolled the whole thing back.
    ///
    /// Deletes still batch, but only across a consecutive run of them. That keeps the case that
    /// matters, selecting many rows and pressing Delete, on one statement, while a delete
    /// separated from another delete by an insert stays on its own side of it.
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
                        statement: stmt, kind: .update, rowIDs: [change.rowID], refusesSharedKey: matchesEitherWay(change)
                    ))
                }
            case .insert:
                // SAFETY: Verify the row is still marked as inserted
                guard insertedRowIDs.contains(change.rowID) else { continue }
                flushDeleteRun()
                if let stmt = generateInsertSQL(for: change, insertedRowData: insertedRowData) {
                    statements.append(AttributedStatement(statement: stmt, kind: .insert, rowIDs: [change.rowID]))
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

    private func placeholder(at index: Int) -> String {
        switch parameterStyle {
        case .dollar:
            return "$\(index + 1)"
        case .questionMark:
            return "?"
        }
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

    /// A cell is written as SQL only when its change says so. Text that merely reads like a function, typed or
    /// stored, is bound like any other value.
    private func generateInsertSQLFromStoredData(values: [PluginCellValue], expressionColumns: Set<Int>)
        -> ParameterizedStatement?
    {
        var nonDefaultColumns: [String] = []
        var placeholderParts: [String] = []
        var bindParameters: [Any?] = []

        for (index, value) in values.enumerated() {
            if case .text(let s) = value, s == "__DEFAULT__" { continue }

            guard index < columns.count else { continue }
            let columnName = columns[index]
            guard !generatedColumns.contains(columnName) else { continue }

            nonDefaultColumns.append(quoteIdentifierFn(columnName))

            switch value {
            case .text(let expression) where expressionColumns.contains(index):
                placeholderParts.append(expression)
            default:
                bindParameters.append(value.asAny)
                placeholderParts.append(placeholder(at: bindParameters.count - 1))
            }
        }

        guard !nonDefaultColumns.isEmpty else { return allDefaultsInsertStatement() }

        let columnList = nonDefaultColumns.joined(separator: ", ")
        let placeholders = placeholderParts.joined(separator: ", ")

        let override = insertOverridesSystemValue ? " OVERRIDING SYSTEM VALUE" : ""
        let sql =
            "INSERT INTO \(qualifiedTableName) (\(columnList))\(override) VALUES (\(placeholders))"

        return ParameterizedStatement(sql: sql, parameters: bindParameters)
    }

    private func allDefaultsInsertStatement() -> ParameterizedStatement? {
        let firstWritable = columns.first { !generatedColumns.contains($0) }.map(quoteIdentifierFn)
        return AllDefaultsInsert.sql(
            into: qualifiedTableName, databaseType: databaseType, firstWritableColumn: firstWritable
        ).map { ParameterizedStatement(sql: $0, parameters: []) }
    }

    func insertStatement(columns insertColumns: [String], values: [PluginCellValue])
        -> ParameterizedStatement?
    {
        guard !insertColumns.isEmpty, insertColumns.count == values.count else { return nil }

        var bindParameters: [Any?] = []
        let columnList = insertColumns.map(quoteIdentifierFn).joined(separator: ", ")
        let placeholders = values.map { value -> String in
            bindParameters.append(value.asAny)
            return placeholder(at: bindParameters.count - 1)
        }.joined(separator: ", ")

        let sql =
            "INSERT INTO \(qualifiedTableName) (\(columnList)) VALUES (\(placeholders))"

        return ParameterizedStatement(sql: sql, parameters: bindParameters)
    }

    func insertStatement(columns insertColumns: [String], rows: [[PluginCellValue]])
        -> ParameterizedStatement?
    {
        guard !insertColumns.isEmpty, !rows.isEmpty,
              rows.allSatisfy({ $0.count == insertColumns.count }) else { return nil }

        var bindParameters: [Any?] = []
        let columnList = insertColumns.map(quoteIdentifierFn).joined(separator: ", ")
        let rowTuples = rows.map { values -> String in
            let placeholders = values.map { value -> String in
                bindParameters.append(value.asAny)
                return placeholder(at: bindParameters.count - 1)
            }.joined(separator: ", ")
            return "(\(placeholders))"
        }.joined(separator: ", ")

        let sql =
            "INSERT INTO \(qualifiedTableName) (\(columnList)) VALUES \(rowTuples)"

        return ParameterizedStatement(sql: sql, parameters: bindParameters)
    }

    var maxBindParameters: Int {
        switch databaseType {
        case .sqlite: 32_766
        case .mssql: 2_100
        default: 65_535
        }
    }

    func deleteAllRowsStatement() -> String {
        "DELETE FROM \(qualifiedTableName)"
    }

    private func generateInsertSQLFromCellChanges(for change: RowChange) -> ParameterizedStatement?
    {
        guard !change.cellChanges.isEmpty else { return nil }

        let nonDefaultChanges = change.cellChanges.filter {
            $0.newValue != .text("__DEFAULT__") && !generatedColumns.contains($0.columnName)
        }

        guard !nonDefaultChanges.isEmpty else { return nil }

        let columnNames = nonDefaultChanges.map {
            quoteIdentifierFn($0.columnName)
        }.joined(separator: ", ")

        var parameters: [Any?] = []
        let placeholders = nonDefaultChanges.map { cellChange -> String in
            switch cellChange.newValue {
            case .text(let expression) where cellChange.newIsExpression:
                return expression
            default:
                parameters.append(cellChange.newValue.asAny)
                return placeholder(at: parameters.count - 1)
            }
        }.joined(separator: ", ")

        let sql =
            "INSERT INTO \(qualifiedTableName) (\(columnNames)) VALUES (\(placeholders))"

        return ParameterizedStatement(sql: sql, parameters: parameters)
    }

    // MARK: - UPDATE Generation

    func generateUpdateSQL(for change: RowChange) -> ParameterizedStatement? {
        guard !change.cellChanges.isEmpty else { return nil }

        let writableChanges = change.cellChanges.filter { !generatedColumns.contains($0.columnName) }
        guard !writableChanges.isEmpty else { return nil }

        var parameters: [Any?] = []
        let setClauses = writableChanges.map { cellChange -> String in
            switch cellChange.newValue {
            case .text(let s) where s == "__DEFAULT__":
                return "\(quoteIdentifierFn(cellChange.columnName)) = DEFAULT"
            case .text(let expression) where cellChange.newIsExpression:
                return "\(quoteIdentifierFn(cellChange.columnName)) = \(expression)"
            default:
                parameters.append(cellChange.newValue.asAny)
                return "\(quoteIdentifierFn(cellChange.columnName)) = \(placeholder(at: parameters.count - 1))"
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

                terms.append(RowMatchTerm(matched: quoteIdentifierFn(pkColumn), value: pkValue))
            }

            guard !terms.isEmpty else { return nil }

            let whereClause = rowCondition(terms, parameters: &parameters)
            let sql =
                "UPDATE \(qualifiedTableName) SET \(setClauses) WHERE \(whereClause)"
            return ParameterizedStatement(sql: sql, parameters: parameters)
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
                terms.append(RowMatchTerm(matched: matched, value: value.isNull ? nil : value))
            }

            guard !terms.isEmpty else { return nil }

            let whereClause = rowCondition(terms, parameters: &parameters)
            let sql =
                "UPDATE \(qualifiedTableName) SET \(setClauses) WHERE \(whereClause)"

            return ParameterizedStatement(sql: sql, parameters: parameters)
        }
    }

    private struct RowMatchTerm {
        let matched: String
        let value: PluginCellValue?
    }

    /// The conditions that pick one row. SQLite keeps the number 5 and the text '5' apart in a column with no
    /// affinity, and the grid read either one as `5`, so a number the grid read matches both, held by CAST to the
    /// text SQLite reads it back as so a REAL 5.0 is not matched too; a typed column converts either literal to its
    /// own type, so the form is exact there too. When both rows exist the statement itself refuses them.
    private func rowCondition(_ terms: [RowMatchTerm], parameters: inout [Any?]) -> String {
        let clause = conditions(terms, parameters: &parameters)
        guard terms.contains(where: { matchesEitherWay($0.value) }) else { return clause }
        let again = conditions(terms, parameters: &parameters)
        return "\(clause) AND (SELECT COUNT(*) FROM \(qualifiedTableName) WHERE \(again)) = 1"
    }

    private func conditions(_ terms: [RowMatchTerm], parameters: inout [Any?]) -> String {
        terms.map { term in
            guard let value = term.value else { return "\(term.matched) IS NULL" }
            parameters.append(value.asAny)
            let bound = placeholder(at: parameters.count - 1)
            guard matchesEitherWay(value), case .text(let text) = value else { return "\(term.matched) = \(bound)" }
            parameters.append(value.asAny)
            let read = placeholder(at: parameters.count - 1)
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
            deleteRowMatches(for: change).map { (rowID: change.rowID, matches: $0) }
        }
        guard !rowMatches.isEmpty else { return [] }

        var statements: [AttributedStatement] = []
        var chunk: [(rowID: RowID, matches: [DeleteColumnMatch])] = []
        var chunkParameterCount = 0

        func flush() {
            statements.append(
                AttributedStatement(
                    statement: deleteStatement(for: chunk.map(\.matches)),
                    kind: .delete,
                    rowIDs: chunk.map(\.rowID),
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
        var parameters: [Any?] = []
        let rowClauses = rows.map { matches -> String in
            let terms = matches.map { match in
                RowMatchTerm(
                    matched: rowMatchPolicy.matchExpression(
                        for: match.column,
                        quoted: quoteIdentifierFn(match.column),
                        value: match.boundValue ?? .null,
                        databaseType: databaseType
                    ),
                    value: match.boundValue
                )
            }
            let joined = rowCondition(terms, parameters: &parameters)
            let isCompound = matches.count > 1 || terms.contains { matchesEitherWay($0.value) }
            return isCompound ? "(\(joined))" : joined
        }

        let whereClause = rowClauses.joined(separator: " OR ")
        let sql = "DELETE FROM \(qualifiedTableName) WHERE \(whereClause)"
        return ParameterizedStatement(sql: sql, parameters: parameters)
    }
}
