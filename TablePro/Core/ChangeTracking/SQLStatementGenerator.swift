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
    let primaryKeyColumn: String?
    let databaseType: DatabaseType
    let parameterStyle: ParameterStyle
    private let quoteIdentifierFn: (String) -> String

    init(
        tableName: String,
        columns: [String],
        primaryKeyColumn: String?,
        databaseType: DatabaseType,
        parameterStyle: ParameterStyle? = nil,
        dialect: SQLDialectDescriptor? = nil,
        quoteIdentifier: ((String) -> String)? = nil
    ) {
        self.tableName = tableName
        self.columns = columns
        self.primaryKeyColumn = primaryKeyColumn
        self.databaseType = databaseType
        self.parameterStyle = parameterStyle ?? Self.defaultParameterStyle(for: databaseType)
        self.quoteIdentifierFn = quoteIdentifier ?? quoteIdentifierFromDialect(dialect)
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
        insertedRowData: [Int: [String?]],
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

    private func generateInsertSQL(for change: RowChange, insertedRowData: [Int: [String?]])
        -> ParameterizedStatement?
    {
        // OPTIMIZATION: Get values from lazy storage instead of cellChanges
        if let values = insertedRowData[change.rowIndex] {
            return generateInsertSQLFromStoredData(rowIndex: change.rowIndex, values: values)
        }

        // Fallback: use cellChanges if stored data not available (backward compatibility)
        return generateInsertSQLFromCellChanges(for: change)
    }

    /// Generate INSERT SQL from lazy-stored row data (optimized path)
    private func generateInsertSQLFromStoredData(rowIndex: Int, values: [String?])
        -> ParameterizedStatement?
    {
        var nonDefaultColumns: [String] = []
        var placeholderParts: [String] = []
        var bindParameters: [Any?] = []

        for (index, value) in values.enumerated() {
            if value == "__DEFAULT__" { continue }

            guard index < columns.count else { continue }
            let columnName = columns[index]

            nonDefaultColumns.append(quoteIdentifierFn(columnName))

            if let val = value {
                if isSQLFunctionExpression(val) {
                    placeholderParts.append(val.trimmingCharacters(in: .whitespaces).uppercased())
                } else {
                    bindParameters.append(val)
                    placeholderParts.append(placeholder(at: bindParameters.count - 1))
                }
            } else {
                bindParameters.append(nil)
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

    /// Generate INSERT SQL from cellChanges (fallback for backward compatibility)
    private func generateInsertSQLFromCellChanges(for change: RowChange) -> ParameterizedStatement?
    {
        guard !change.cellChanges.isEmpty else { return nil }

        // Filter out DEFAULT columns - let DB handle them
        let nonDefaultChanges = change.cellChanges.filter {
            $0.newValue != "__DEFAULT__"
        }

        // If all columns are DEFAULT, don't generate INSERT
        guard !nonDefaultChanges.isEmpty else { return nil }

        let columnNames = nonDefaultChanges.map {
            quoteIdentifierFn($0.columnName)
        }.joined(separator: ", ")

        var parameters: [Any?] = []
        let placeholders = nonDefaultChanges.map { cellChange -> String in
            if let newValue = cellChange.newValue {
                if isSQLFunctionExpression(newValue) {
                    // SQL function - cannot parameterize, use literal
                    return newValue.trimmingCharacters(in: .whitespaces).uppercased()
                }
                parameters.append(newValue)
                return placeholder(at: parameters.count - 1)
            }
            parameters.append(nil)
            return placeholder(at: parameters.count - 1)
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

    /// Generate individual UPDATE statement for a single row using parameterized query
    func generateUpdateSQL(for change: RowChange) -> ParameterizedStatement? {
        guard !change.cellChanges.isEmpty else { return nil }

        var parameters: [Any?] = []
        let setClauses = change.cellChanges.map { cellChange -> String in
            if cellChange.newValue == "__DEFAULT__" {
                return "\(quoteIdentifierFn(cellChange.columnName)) = DEFAULT"
            } else if let newValue = cellChange.newValue {
                if isSQLFunctionExpression(newValue) {
                    return
                        "\(quoteIdentifierFn(cellChange.columnName)) = \(newValue.trimmingCharacters(in: .whitespaces).uppercased())"
                } else {
                    parameters.append(newValue)
                    return
                        "\(quoteIdentifierFn(cellChange.columnName)) = \(placeholder(at: parameters.count - 1))"
                }
            } else {
                parameters.append(nil)
                return
                    "\(quoteIdentifierFn(cellChange.columnName)) = \(placeholder(at: parameters.count - 1))"
            }
        }.joined(separator: ", ")

        if let pkColumn = primaryKeyColumn,
            let pkColumnIndex = columns.firstIndex(of: pkColumn)
        {
            var pkValue: Any?
            if let originalRow = change.originalRow, pkColumnIndex < originalRow.count {
                pkValue = originalRow[pkColumnIndex]
            } else if let pkChange = change.cellChanges.first(where: { $0.columnName == pkColumn })
            {
                pkValue = pkChange.oldValue
            }

            guard pkValue != nil else {
                Self.logger.warning(
                    "Skipping UPDATE for table '\(self.tableName)' - cannot determine primary key value for row"
                )
                return nil
            }

            parameters.append(pkValue)
            let whereClause =
                "\(quoteIdentifierFn(pkColumn)) = \(placeholder(at: parameters.count - 1))"
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
                if let value = value {
                    parameters.append(value)
                    conditions.append("\(quotedColumn) = \(placeholder(at: parameters.count - 1))")
                } else {
                    conditions.append("\(quotedColumn) IS NULL")
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

        // If we have a primary key, use it for efficient deletion
        if let pkColumn = primaryKeyColumn,
            let pkIndex = columns.firstIndex(of: pkColumn)
        {
            // Build OR conditions for all rows using PK
            var parameters: [Any?] = []
            let conditions = changes.compactMap { change -> String? in
                guard let originalRow = change.originalRow,
                    pkIndex < originalRow.count
                else {
                    return nil
                }

                parameters.append(originalRow[pkIndex])
                return
                    "\(quoteIdentifierFn(pkColumn)) = \(placeholder(at: parameters.count - 1))"
            }

            guard !conditions.isEmpty else { return nil }

            let whereClause = conditions.joined(separator: " OR ")
            let sql = "DELETE FROM \(quoteIdentifierFn(tableName)) WHERE \(whereClause)"

            return ParameterizedStatement(sql: sql, parameters: parameters)
        }

        // Fallback: No primary key - generate individual DELETE statements
        return nil
    }

    /// Generate individual DELETE statement for a single row (used when no PK or as fallback)
    private func generateDeleteSQL(for change: RowChange) -> ParameterizedStatement? {
        guard let originalRow = change.originalRow else { return nil }

        // Build WHERE clause matching ALL columns to uniquely identify the row
        var parameters: [Any?] = []
        var conditions: [String] = []

        for (index, columnName) in columns.enumerated() {
            guard index < originalRow.count else { continue }

            let value = originalRow[index]
            let quotedColumn = quoteIdentifierFn(columnName)

            if let value = value {
                parameters.append(value)
                conditions.append("\(quotedColumn) = \(placeholder(at: parameters.count - 1))")
            } else {
                conditions.append("\(quotedColumn) IS NULL")
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
