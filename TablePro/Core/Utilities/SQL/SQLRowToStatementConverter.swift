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
    ) throws {
        self.tableName = tableName
        self.columns = columns
        self.primaryKeyColumn = primaryKeyColumn
        self.databaseType = databaseType

        if let quoteIdentifier, let escapeStringLiteral {
            self.quoteIdentifierFn = quoteIdentifier
            self.escapeStringFn = escapeStringLiteral
            return
        }

        let resolvedDialect = try resolveSQLDialect(for: databaseType, explicit: dialect)
        self.quoteIdentifierFn = quoteIdentifier ?? quoteIdentifierFromDialect(resolvedDialect)
        self.escapeStringFn = escapeStringLiteral ?? Self.defaultEscapeFunction(dialect: resolvedDialect)
    }

    private static let maxRows = 50_000

    private static func defaultEscapeFunction(dialect: SQLDialectDescriptor) -> (String) -> String {
        if dialect.requiresBackslashEscaping {
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

    internal func generateInserts(rows: [[PluginCellValue]]) -> String {
        let capped = rows.prefix(Self.maxRows)
        let quotedTable = quoteColumn(tableName)
        let quotedColumns = columns.map { quoteColumn($0) }.joined(separator: ", ")

        return capped.map { row in
            let values = row.map { formatValue($0) }.joined(separator: ", ")
            return "INSERT INTO \(quotedTable) (\(quotedColumns)) VALUES (\(values));"
        }.joined(separator: "\n")
    }

    internal func generateUpdates(rows: [[PluginCellValue]]) -> String {
        let capped = rows.prefix(Self.maxRows)

        return capped.map { row in
            buildUpdateStatement(row: row)
        }.joined(separator: "\n")
    }

    private func buildUpdateStatement(row: [PluginCellValue]) -> String {
        let quotedTable = quoteColumn(tableName)

        let setClause: String
        let whereClause: String

        if let pkColumn = primaryKeyColumn,
           let pkIndex = columns.firstIndex(of: pkColumn),
           row.indices.contains(pkIndex) {
            let pkValue = row[pkIndex]

            let setClauses = columns.enumerated().compactMap { index, col -> String? in
                guard col != pkColumn else { return nil }
                let value = row.indices.contains(index) ? row[index] : .null
                return "\(quoteColumn(col)) = \(formatValue(value))"
            }
            setClause = setClauses.joined(separator: ", ")
            if pkValue.isNull {
                whereClause = "\(quoteColumn(pkColumn)) IS NULL"
            } else {
                whereClause = "\(quoteColumn(pkColumn)) = \(formatValue(pkValue))"
            }
        } else {
            let allClauses = columns.enumerated().map { index, col -> String in
                let value = row.indices.contains(index) ? row[index] : .null
                return "\(quoteColumn(col)) = \(formatValue(value))"
            }
            setClause = allClauses.joined(separator: ", ")

            let whereParts = columns.enumerated().map { index, col -> String in
                let value = row.indices.contains(index) ? row[index] : .null
                if value.isNull {
                    return "\(quoteColumn(col)) IS NULL"
                }
                return "\(quoteColumn(col)) = \(formatValue(value))"
            }
            whereClause = whereParts.joined(separator: " AND ")
        }

        return "UPDATE \(quotedTable) SET \(setClause) WHERE \(whereClause);"
    }

    private func formatValue(_ value: PluginCellValue) -> String {
        switch value {
        case .null:
            return "NULL"
        case .text(let s):
            return "'\(escapeStringFn(s))'"
        case .bytes(let data):
            return formatBinaryLiteral(data)
        }
    }

    private func formatBinaryLiteral(_ data: Data) -> String {
        var hex = ""
        hex.reserveCapacity(data.count * 2)
        for byte in data {
            hex += String(format: "%02X", byte)
        }
        switch databaseType {
        case .postgresql, .redshift:
            return "'\\x\(hex)'::bytea"
        case .mssql:
            return "0x\(hex)"
        default:
            return "X'\(hex)'"
        }
    }

    private func quoteColumn(_ name: String) -> String {
        quoteIdentifierFn(name)
    }
}
