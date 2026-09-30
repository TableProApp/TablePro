//
//  MSSQLStatementGenerator.swift
//  MSSQLDriverPlugin
//

import Foundation
import TableProPluginKit

/// The INSERT, UPDATE and DELETE statements a grid save sends to SQL Server, with `?` placeholders.
///
/// A table with no primary key is matched on every column and bounded with `TOP (1)`, so a save never touches a
/// second row that happens to look the same.
struct MSSQLStatementGenerator {
    /// What the grid stages for a column the user leaves to the server's default. It is a marker, never a value.
    static let defaultMarker = PluginCellValue.text("__DEFAULT__")

    let qualifiedTable: String
    let columns: [String]
    let primaryKeyColumns: [String]

    func statements(
        for changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [PluginCellValue])] {
        var writes: [(statement: String, parameters: [PluginCellValue])] = []
        var deletes: [(statement: String, parameters: [PluginCellValue])] = []
        for change in changes {
            switch change.type {
            case .insert:
                guard insertedRowIndices.contains(change.rowIndex),
                      let values = insertedRowData[change.rowIndex] else { continue }
                writes.append(insertStatement(values: values))
            case .update:
                guard let statement = updateStatement(for: change) else { continue }
                writes.append(statement)
            case .delete:
                guard deletedRowIndices.contains(change.rowIndex),
                      let statement = deleteStatement(for: change) else { continue }
                deletes.append(statement)
            }
        }
        return writes + deletes
    }

    func insertStatement(values: [PluginCellValue]) -> (statement: String, parameters: [PluginCellValue]) {
        let written = zip(columns, values).filter { $0.1 != Self.defaultMarker }
        guard !written.isEmpty else {
            return (statement: "INSERT INTO \(qualifiedTable) DEFAULT VALUES", parameters: [])
        }
        let columnList = written.map { Self.quote($0.0) }.joined(separator: ", ")
        let placeholders = written.map { _ in "?" }.joined(separator: ", ")
        return (
            statement: "INSERT INTO \(qualifiedTable) (\(columnList)) VALUES (\(placeholders))",
            parameters: written.map(\.1)
        )
    }

    func updateStatement(for change: PluginRowChange) -> (statement: String, parameters: [PluginCellValue])? {
        guard !change.cellChanges.isEmpty, let originalRow = change.originalRow else { return nil }

        var parameters: [PluginCellValue] = []
        let assignments = change.cellChanges.map { cellChange -> String in
            let column = Self.quote(cellChange.columnName)
            guard cellChange.newValue != Self.defaultMarker else { return "\(column) = DEFAULT" }
            parameters.append(cellChange.newValue)
            return "\(column) = ?"
        }

        guard let match = rowMatch(originalRow: originalRow) else { return nil }
        parameters.append(contentsOf: match.parameters)
        let sql = "UPDATE \(topClause)\(qualifiedTable) SET \(assignments.joined(separator: ", ")) WHERE \(match.sql)"
        return (statement: sql, parameters: parameters)
    }

    func deleteStatement(for change: PluginRowChange) -> (statement: String, parameters: [PluginCellValue])? {
        guard let originalRow = change.originalRow, let match = rowMatch(originalRow: originalRow) else { return nil }
        return (statement: "DELETE \(topClause)FROM \(qualifiedTable) WHERE \(match.sql)", parameters: match.parameters)
    }

    private var topClause: String {
        primaryKeyColumns.isEmpty ? "TOP (1) " : ""
    }

    private func rowMatch(originalRow: [PluginCellValue]) -> (sql: String, parameters: [PluginCellValue])? {
        let matchColumns = primaryKeyColumns.isEmpty ? columns : primaryKeyColumns
        var conditions: [String] = []
        var parameters: [PluginCellValue] = []
        for column in matchColumns {
            guard let index = columns.firstIndex(of: column), index < originalRow.count else { continue }
            let value = originalRow[index]
            if value.isNull {
                conditions.append("\(Self.quote(column)) IS NULL")
            } else {
                parameters.append(value)
                conditions.append("\(Self.quote(column)) = ?")
            }
        }
        guard !conditions.isEmpty else { return nil }
        return (sql: conditions.joined(separator: " AND "), parameters: parameters)
    }

    static func quote(_ name: String) -> String {
        "[\(name.replacingOccurrences(of: "]", with: "]]"))]"
    }
}
