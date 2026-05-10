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

        // Generate DELETE statements
        // Try batched DELETE first (uses PK if available), fall back to individual DELETEs
        if !deleteChanges.isEmpty {
            if let stmt = generateBatchDeleteSQL(for: deleteChanges) {
                // Batched delete successful (has PK)
                statements.append(stmt)
            } else {
                // No PK - generate individual DELETE statements matching all columns
                for change in deleteChanges {
                    if let stmt = generateDeleteSQL(for: change) {
                        statements.append(stmt)
                    }
                }
            }
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

    /// Marker type for SQL function literals that cannot be parameterized
    private struct SQLFunctionLiteral {
        let value: String
        init(_ value: String) { self.value = value }
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

    /// Generate a batched DELETE statement combining multiple rows
    private func generateBatchDeleteSQL(for changes: [RowChange]) -> ParameterizedStatement? {
        guard !changes.isEmpty else { return nil }

        // If we have primary key(s), use them for efficient deletion
        if !primaryKeyColumns.isEmpty {
            let pkIndices: [(column: String, index: Int)] = primaryKeyColumns.compactMap { col in
                guard let idx = columns.firstIndex(of: col) else { return nil }
                return (col, idx)
            }
            guard !pkIndices.isEmpty else { return nil }

            var parameters: [Any?] = []
            let rowConditions = changes.compactMap { change -> String? in
                guard let originalRow = change.originalRow else { return nil }

                var pkConditions: [String] = []
                for pk in pkIndices {
                    guard pk.index < originalRow.count else { return nil }
                    parameters.append(originalRow[pk.index].asAny)
                    pkConditions.append(
                        "\(quoteIdentifierFn(pk.column)) = \(placeholder(at: parameters.count - 1))"
                    )
                }
                return pkIndices.count > 1
                    ? "(\(pkConditions.joined(separator: " AND ")))"
                    : pkConditions.joined()
            }

            guard !rowConditions.isEmpty else { return nil }

            let whereClause = rowConditions.joined(separator: " OR ")
            let sql = "DELETE FROM \(quoteIdentifierFn(tableName)) WHERE \(whereClause)"

            return ParameterizedStatement(sql: sql, parameters: parameters)
        }

        // Fallback: No primary key - generate individual DELETE statements
        return nil
    }

    private func generateDeleteSQL(for change: RowChange) -> ParameterizedStatement? {
        guard let originalRow = change.originalRow else { return nil }

        var parameters: [Any?] = []
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
        let sql = "DELETE FROM \(quoteIdentifierFn(tableName)) WHERE \(whereClause)"

        return ParameterizedStatement(sql: sql, parameters: parameters)
    }

    // MARK: - Helper Functions

    /// Check if a string is a SQL function expression that should not be quoted
    private func isSQLFunctionExpression(_ value: String) -> Bool {
        SQLEscaping.isTemporalFunction(value)
    }
}
