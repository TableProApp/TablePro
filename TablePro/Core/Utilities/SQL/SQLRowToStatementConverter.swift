//
//  SQLRowToStatementConverter.swift
//  TablePro

import Foundation
import TableProPluginKit

internal struct SQLRowToStatementConverter {
    internal let tableName: String
    internal let columns: [String]
    internal let primaryKeyColumn: String?
    internal let databaseType: DatabaseType
    private let quoteIdentifierFn: (String) -> String
    private let escapeStringFn: (String) -> String

    init(
        tableName: String,
        columns: [String],
        primaryKeyColumn: String?,
        databaseType: DatabaseType,
        dialect: SQLDialectDescriptor? = nil,
        quoteIdentifier: ((String) -> String)? = nil,
        escapeStringLiteral: ((String) -> String)? = nil
    ) {
        self.tableName = tableName
        self.columns = columns
        self.primaryKeyColumn = primaryKeyColumn
        self.databaseType = databaseType
        self.quoteIdentifierFn = quoteIdentifier ?? quoteIdentifierFromDialect(dialect)
        self.escapeStringFn = escapeStringLiteral ?? Self.defaultEscapeFunction(dialect: dialect)
    }

    private static let maxRows = 50_000

    /// Fallback escape function when no plugin driver is available.
    /// Dialects with `requiresBackslashEscaping` get backslash escaping; others use ANSI SQL.
    private static func defaultEscapeFunction(dialect: SQLDialectDescriptor?) -> (String) -> String {
        if dialect?.requiresBackslashEscaping == true {
            return { value in
                var result = value
                result = result.replacingOccurrences(of: "\\", with: "\\\\")
                result = result.replacingOccurrences(of: "'", with: "''")
                result = result.replacingOccurrences(of: "\0", with: "\\0")
                return result
            }
        }
        return SQLEscaping.escapeStringLiteral
    }

    internal func generateInserts(rows: [[String?]]) -> String {
        let capped = rows.prefix(Self.maxRows)
        let quotedTable = quoteColumn(tableName)
        let quotedColumns = columns.map { quoteColumn($0) }.joined(separator: ", ")

        return capped.map { row in
            let values = row.map { formatValue($0) }.joined(separator: ", ")
            return "INSERT INTO \(quotedTable) (\(quotedColumns)) VALUES (\(values));"
        }.joined(separator: "\n")
    }

    internal func generateUpdates(rows: [[String?]]) -> String {
        let capped = rows.prefix(Self.maxRows)

        return capped.map { row in
            buildUpdateStatement(row: row)
        }.joined(separator: "\n")
    }

    // MARK: - Private Helpers

    private func buildUpdateStatement(row: [String?]) -> String {
        let quotedTable = quoteColumn(tableName)

        let setClause: String
        let whereClause: String

        if let pkColumn = primaryKeyColumn,
           let pkIndex = columns.firstIndex(of: pkColumn),
           row.indices.contains(pkIndex) {
            let pkValue = row[pkIndex]

            let setClauses = columns.enumerated().compactMap { index, col -> String? in
                guard col != pkColumn else { return nil }
                let value = row.indices.contains(index) ? row[index] : nil
                return "\(quoteColumn(col)) = \(formatValue(value))"
            }
            setClause = setClauses.joined(separator: ", ")
            if pkValue == nil {
                whereClause = "\(quoteColumn(pkColumn)) IS NULL"
            } else {
                whereClause = "\(quoteColumn(pkColumn)) = \(formatValue(pkValue))"
            }
        } else {
            let allClauses = columns.enumerated().map { index, col -> String in
                let value = row.indices.contains(index) ? row[index] : nil
                return "\(quoteColumn(col)) = \(formatValue(value))"
            }
            setClause = allClauses.joined(separator: ", ")

            let whereParts = columns.enumerated().map { index, col -> String in
                let value = row.indices.contains(index) ? row[index] : nil
                if value == nil {
                    return "\(quoteColumn(col)) IS NULL"
                }
                return "\(quoteColumn(col)) = \(formatValue(value))"
            }
            whereClause = whereParts.joined(separator: " AND ")
        }

        return "UPDATE \(quotedTable) SET \(setClause) WHERE \(whereClause);"
    }

    private func formatValue(_ value: String?) -> String {
        guard let value else {
            return "NULL"
        }
        let escaped = escapeStringFn(value)
        return "'\(escaped)'"
    }

    private func quoteColumn(_ name: String) -> String {
        quoteIdentifierFn(name)
    }
}
