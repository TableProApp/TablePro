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

/// A parameterized SQL statement with placeholders and bound values
struct ParameterizedStatement {
    let sql: String
    let parameters: [Any?]
}

/// Generates SQL statements from data changes
struct SQLStatementGenerator {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLStatementGenerator")

    let tableName: String
    let columns: [String]
    let primaryKeyColumns: [String]
    let databaseType: DatabaseType
    let parameterStyle: ParameterStyle
    private let quoteIdentifierFn: (String) -> String

    init(
        tableName: String,
        columns: [String],
        primaryKeyColumns: [String],
        databaseType: DatabaseType,
        parameterStyle: ParameterStyle? = nil,
        dialect: SQLDialectDescriptor? = nil,
        quoteIdentifier: ((String) -> String)? = nil
    ) throws {
        self.tableName = tableName
        self.columns = columns
        self.primaryKeyColumns = primaryKeyColumns
        self.databaseType = databaseType
        self.parameterStyle = parameterStyle ?? Self.defaultParameterStyle(for: databaseType)
        if let quoteIdentifier {
            self.quoteIdentifierFn = quoteIdentifier
        } else {
            let resolvedDialect = try resolveSQLDialect(for: databaseType, explicit: dialect)
            self.quoteIdentifierFn = quoteIdentifierFromDialect(resolvedDialect)
        }
    }

    private static func defaultParameterStyle(for databaseType: DatabaseType) -> ParameterStyle {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?.parameterStyle ?? .questionMark
    }

    // MARK: - Public API

    /// Generate all parameterized SQL statements from changes
    /// - Parameters:
    ///   - changes: Array of row changes to process
    ///   - insertedRowData: Lazy storage for inserted row values
    ///   - deletedRowIndices: Set of deleted row indices for validation
    ///   - insertedRowIndices: Set of inserted row indices for validation
    /// - Returns: Array of parameterized SQL statements
    func generateStatements(
        from changes: [RowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [ParameterizedStatement] {
        var statements: [ParameterizedStatement] = []

        // Collect UPDATE and DELETE changes to batch them
        var updateChanges: [RowChange] = []
        var deleteChanges: [RowChange] = []

        for change in changes {
            switch change.type {
            case .update:
                updateChanges.append(change)
            case .insert:
                // SAFETY: Verify the row is still marked as inserted
                guard insertedRowIndices.contains(change.rowIndex) else {
                    continue
                }
                if let stmt = generateInsertSQL(for: change, insertedRowData: insertedRowData) {
                    statements.append(stmt)
                }
            case .delete:
                // SAFETY: Verify the row is still marked as deleted
                guard deletedRowIndices.contains(change.rowIndex) else {
                    continue
                }
                deleteChanges.append(change)
            }
        }

        // Generate individual UPDATE statements (safer than batched CASE/WHEN)
        if !updateChanges.isEmpty {
            for change in updateChanges {
                if let stmt = generateUpdateSQL(for: change) {
                    statements.append(stmt)
                }
            }
        }

        if !deleteChanges.isEmpty {
            statements.append(contentsOf: generateDeleteStatements(for: deleteChanges))
        }

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

    private func generateInsertSQL(for change: RowChange, insertedRowData: [Int: [PluginCellValue]])
        -> ParameterizedStatement?
    {
        if let values = insertedRowData[change.rowIndex] {
            return generateInsertSQLFromStoredData(rowIndex: change.rowIndex, values: values)
        }
        return generateInsertSQLFromCellChanges(for: change)
    }

    private func generateInsertSQLFromStoredData(rowIndex: Int, values: [PluginCellValue])
        -> ParameterizedStatement?
    {
        var nonDefaultColumns: [String] = []
        var placeholderParts: [String] = []
        var bindParameters: [Any?] = []

        for (index, value) in values.enumerated() {
            if case .text(let s) = value, s == "__DEFAULT__" { continue }

            guard index < columns.count else { continue }
            let columnName = columns[index]

            nonDefaultColumns.append(quoteIdentifierFn(columnName))

            switch value {
            case .text(let s) where isSQLFunctionExpression(s):
                placeholderParts.append(s.trimmingCharacters(in: .whitespaces).uppercased())
            default:
                bindParameters.append(value.asAny)
                placeholderParts.append(placeholder(at: bindParameters.count - 1))
            }
        }

        guard !nonDefaultColumns.isEmpty else { return nil }

        let columnList = nonDefaultColumns.joined(separator: ", ")
        let placeholders = placeholderParts.joined(separator: ", ")

        let sql =
            "INSERT INTO \(quoteIdentifierFn(tableName)) (\(columnList)) VALUES (\(placeholders))"

        return ParameterizedStatement(sql: sql, parameters: bindParameters)
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
            "INSERT INTO \(quoteIdentifierFn(tableName)) (\(columnList)) VALUES (\(placeholders))"

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
            "INSERT INTO \(quoteIdentifierFn(tableName)) (\(columnList)) VALUES \(rowTuples)"

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
        "DELETE FROM \(quoteIdentifierFn(tableName))"
    }

    private func generateInsertSQLFromCellChanges(for change: RowChange) -> ParameterizedStatement?
    {
        guard !change.cellChanges.isEmpty else { return nil }

        let nonDefaultChanges = change.cellChanges.filter { $0.newValue != .text("__DEFAULT__") }

        guard !nonDefaultChanges.isEmpty else { return nil }

        let columnNames = nonDefaultChanges.map {
            quoteIdentifierFn($0.columnName)
        }.joined(separator: ", ")

        var parameters: [Any?] = []
        let placeholders = nonDefaultChanges.map { cellChange -> String in
            switch cellChange.newValue {
            case .text(let s) where isSQLFunctionExpression(s):
                return s.trimmingCharacters(in: .whitespaces).uppercased()
            default:
                parameters.append(cellChange.newValue.asAny)
                return placeholder(at: parameters.count - 1)
            }
        }.joined(separator: ", ")

        let sql =
            "INSERT INTO \(quoteIdentifierFn(tableName)) (\(columnNames)) VALUES (\(placeholders))"

        return ParameterizedStatement(sql: sql, parameters: parameters)
    }

    // MARK: - UPDATE Generation

    func generateUpdateSQL(for change: RowChange) -> ParameterizedStatement? {
        guard !change.cellChanges.isEmpty else { return nil }

        var parameters: [Any?] = []
        let setClauses = change.cellChanges.map { cellChange -> String in
            switch cellChange.newValue {
            case .text(let s) where s == "__DEFAULT__":
                return "\(quoteIdentifierFn(cellChange.columnName)) = DEFAULT"
            case .text(let s) where isSQLFunctionExpression(s):
                return "\(quoteIdentifierFn(cellChange.columnName)) = \(s.trimmingCharacters(in: .whitespaces).uppercased())"
            default:
                parameters.append(cellChange.newValue.asAny)
                return "\(quoteIdentifierFn(cellChange.columnName)) = \(placeholder(at: parameters.count - 1))"
            }
        }.joined(separator: ", ")

        if !primaryKeyColumns.isEmpty {
            var conditions: [String] = []

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

                parameters.append(pkValue.asAny)
                conditions.append(
                    "\(quoteIdentifierFn(pkColumn)) = \(placeholder(at: parameters.count - 1))"
                )
            }

            guard !conditions.isEmpty else { return nil }

            let whereClause = conditions.joined(separator: " AND ")
            let sql =
                "UPDATE \(quoteIdentifierFn(tableName)) SET \(setClauses) WHERE \(whereClause)"
            return ParameterizedStatement(sql: sql, parameters: parameters)
        } else {
            guard let originalRow = change.originalRow else {
                Self.logger.warning(
                    "Skipping UPDATE for table '\(self.tableName)' - no primary key and no original row data"
                )
                return nil
            }

            var conditions: [String] = []
            for (index, columnName) in columns.enumerated() {
                guard index < originalRow.count else { continue }
                let value = originalRow[index]
                let quotedColumn = quoteIdentifierFn(columnName)
                if value.isNull {
                    conditions.append("\(quotedColumn) IS NULL")
                } else {
                    parameters.append(value.asAny)
                    conditions.append("\(quotedColumn) = \(placeholder(at: parameters.count - 1))")
                }
            }

            guard !conditions.isEmpty else { return nil }

            let whereClause = conditions.joined(separator: " AND ")
            let sql =
                "UPDATE \(quoteIdentifierFn(tableName)) SET \(setClauses) WHERE \(whereClause)"

            return ParameterizedStatement(sql: sql, parameters: parameters)
        }
    }

    // MARK: - DELETE Generation

    private struct DeleteColumnMatch {
        let column: String
        let boundValue: PluginCellValue?
    }

    private func generateDeleteStatements(for changes: [RowChange]) -> [ParameterizedStatement] {
        let rowMatches = changes.compactMap { deleteRowMatches(for: $0) }
        guard !rowMatches.isEmpty else { return [] }

        var statements: [ParameterizedStatement] = []
        var chunk: [[DeleteColumnMatch]] = []
        var chunkParameterCount = 0

        for matches in rowMatches {
            let rowParameterCount = matches.count(where: { $0.boundValue != nil })
            if !chunk.isEmpty, chunkParameterCount + rowParameterCount > maxBindParameters {
                statements.append(deleteStatement(for: chunk))
                chunk = []
                chunkParameterCount = 0
            }
            chunk.append(matches)
            chunkParameterCount += rowParameterCount
        }

        if !chunk.isEmpty {
            statements.append(deleteStatement(for: chunk))
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
            guard index < originalRow.count else { continue }
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
            let conditions = matches.map { match -> String in
                guard let value = match.boundValue else {
                    return "\(quoteIdentifierFn(match.column)) IS NULL"
                }
                parameters.append(value.asAny)
                return "\(quoteIdentifierFn(match.column)) = \(placeholder(at: parameters.count - 1))"
            }
            let joined = conditions.joined(separator: " AND ")
            return matches.count > 1 ? "(\(joined))" : joined
        }

        let whereClause = rowClauses.joined(separator: " OR ")
        let sql = "DELETE FROM \(quoteIdentifierFn(tableName)) WHERE \(whereClause)"
        return ParameterizedStatement(sql: sql, parameters: parameters)
    }

    // MARK: - Helper Functions

    /// Check if a string is a SQL function expression that should not be quoted
    private func isSQLFunctionExpression(_ value: String) -> Bool {
        SQLEscaping.isTemporalFunction(value)
    }
}
