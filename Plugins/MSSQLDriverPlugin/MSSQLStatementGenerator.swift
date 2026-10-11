//
//  MSSQLStatementGenerator.swift
//  MSSQLDriverPlugin
//

import Foundation
import TableProMSSQLCore
import TableProPluginKit

/// The INSERT, UPDATE and DELETE statements a grid save sends to SQL Server, with `?` placeholders.
///
/// A table with no primary key is matched on every column and bounded with `TOP (1)`, so a save never touches a
/// second row that happens to look the same. That bound is only safe when every column takes part in the match: a
/// match with one left out can pick a different row, so such a change is refused instead.
struct MSSQLStatementGenerator {
    /// What the grid stages for a column the user leaves to the server's default. It is a marker, never a value.
    static let defaultMarker = PluginCellValue.text("__DEFAULT__")

    let qualifiedTable: String
    let columns: [String]
    let primaryKeyColumns: [String]
    var context = PluginRowWriteContext()

    func rowWrites(
        for changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) throws -> [PluginRowWrite] {
        var writes: [PluginRowWrite] = []
        var deletes: [PluginRowWrite] = []
        for change in changes {
            switch change.type {
            case .insert:
                guard insertedRowIndices.contains(change.rowIndex),
                      let values = insertedRowData[change.rowIndex] else { continue }
                let statement = try insertStatement(values: values, rowIndex: change.rowIndex)
                writes.append(PluginRowWrite(statement: statement.statement, parameters: statement.parameters, rowIndices: [change.rowIndex]))
            case .update:
                guard let statement = try updateStatement(for: change) else { continue }
                writes.append(PluginRowWrite(statement: statement.statement, parameters: statement.parameters, rowIndices: [change.rowIndex]))
            case .delete:
                guard deletedRowIndices.contains(change.rowIndex),
                      let statement = try deleteStatement(for: change) else { continue }
                deletes.append(PluginRowWrite(statement: statement.statement, parameters: statement.parameters, rowIndices: [change.rowIndex]))
            }
        }
        return writes + deletes
    }

    /// The statements alone, for a host that asks without a context. With no context there is nothing to refuse.
    func statements(
        for changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [PluginCellValue])] {
        let writes = (try? rowWrites(
            for: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: deletedRowIndices,
            insertedRowIndices: insertedRowIndices
        )) ?? []
        return writes.map { (statement: $0.statement, parameters: $0.parameters) }
    }

    func insertStatement(
        values: [PluginCellValue],
        rowIndex: Int = 0
    ) throws -> (statement: String, parameters: [PluginCellValue]) {
        let written = zip(columns, values).filter { $0.1 != Self.defaultMarker }
        if let owned = written.first(where: { context.serverOwnedColumns.contains($0.0) }) {
            throw PluginRowWriteRefusal(rowIndex: rowIndex, reason: Self.serverOwnedReason(owned.0))
        }
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

    func updateStatement(for change: PluginRowChange) throws -> (statement: String, parameters: [PluginCellValue])? {
        guard !change.cellChanges.isEmpty, let originalRow = change.originalRow else { return nil }
        if let owned = change.cellChanges.first(where: { context.serverOwnedColumns.contains($0.columnName) }) {
            throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: Self.serverOwnedReason(owned.columnName))
        }

        var parameters: [PluginCellValue] = []
        let assignments = change.cellChanges.map { cellChange -> String in
            let column = Self.quote(cellChange.columnName)
            guard cellChange.newValue != Self.defaultMarker else { return "\(column) = DEFAULT" }
            parameters.append(cellChange.newValue)
            return "\(column) = ?"
        }

        guard let match = try rowMatch(originalRow: originalRow, rowIndex: change.rowIndex) else { return nil }
        parameters.append(contentsOf: match.parameters)
        let sql = "UPDATE \(topClause)\(qualifiedTable) SET \(assignments.joined(separator: ", ")) WHERE \(match.sql)"
        return (statement: countReported(sql, parameters: parameters), parameters: parameters)
    }

    func deleteStatement(for change: PluginRowChange) throws -> (statement: String, parameters: [PluginCellValue])? {
        guard let originalRow = change.originalRow,
              let match = try rowMatch(originalRow: originalRow, rowIndex: change.rowIndex) else { return nil }
        let sql = "DELETE \(topClause)FROM \(qualifiedTable) WHERE \(match.sql)"
        return (statement: countReported(sql, parameters: match.parameters), parameters: match.parameters)
    }

    private var topClause: String {
        primaryKeyColumns.isEmpty ? "TOP (1) " : ""
    }

    /// The app holds a keyless write to the row it matched, and under `SET NOCOUNT ON` the server reports no count.
    /// A SET inside `sp_executesql` reverts when the call returns. A bound statement already runs in one, so only an
    /// unbound one, a row whose every column is NULL, is given its own.
    private func countReported(_ sql: String, parameters: [PluginCellValue]) -> String {
        guard primaryKeyColumns.isEmpty else { return sql }
        let counted = "SET NOCOUNT OFF; \(sql)"
        guard parameters.isEmpty else { return counted }
        return "EXEC sp_executesql \(MSSQLStringLiteral.quoted(counted))"
    }

    private func rowMatch(
        originalRow: [PluginCellValue],
        rowIndex: Int
    ) throws -> (sql: String, parameters: [PluginCellValue])? {
        let isKeyless = primaryKeyColumns.isEmpty
        let matchColumns = isKeyless ? columns : primaryKeyColumns
        var conditions: [String] = []
        var parameters: [PluginCellValue] = []
        for column in matchColumns {
            guard let index = columns.firstIndex(of: column), index < originalRow.count else { continue }
            if isKeyless, context.rowMatchExcludedColumns.contains(column) {
                throw PluginRowWriteRefusal(rowIndex: rowIndex, reason: Self.unmatchableReason(column))
            }
            let value = originalRow[index]
            let compared = isKeyless ? keylessExpression(for: column, value: value) : Self.quote(column)
            if value.isNull {
                conditions.append("\(compared) IS NULL")
            } else {
                parameters.append(value)
                conditions.append("\(compared) = ?")
            }
        }
        guard !conditions.isEmpty else { return nil }
        return (sql: conditions.joined(separator: " AND "), parameters: parameters)
    }

    /// SQL Server refuses `=` on `ntext`, `text`, `image` and `xml` (Msg 402), `sql_variant` (206) and the spatial
    /// types (403). Cast to the type the value is bound as, each compares exactly (measured on SQL Server 2022).
    private func keylessExpression(for column: String, value: PluginCellValue) -> String {
        guard context.rowMatchTextColumns.contains(column) else { return Self.quote(column) }
        let target = value.asBytes == nil ? "NVARCHAR(MAX)" : "VARBINARY(MAX)"
        return "CAST(\(Self.quote(column)) AS \(target))"
    }

    private static func serverOwnedReason(_ column: String) -> String {
        String(format: String(localized: "The server fills in %@, so it cannot be given a value."), column)
    }

    private static func unmatchableReason(_ column: String) -> String {
        String(
            format: String(localized: "This table has no primary key, and %@ cannot be compared to find the row."),
            column
        )
    }

    static func quote(_ name: String) -> String {
        "[\(name.replacingOccurrences(of: "]", with: "]]"))]"
    }
}
