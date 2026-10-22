//
//  SnowflakeStatementGenerator.swift
//  SnowflakeDriverPlugin
//
//  Generates Snowflake DML from tracked grid changes using server-side bind
//  placeholders. Semi-structured columns (VARIANT, OBJECT, ARRAY) bind through
//  PARSE_JSON, which Snowflake rejects inside a VALUES clause, so inserts that
//  touch them use the INSERT INTO ... SELECT form.
//

import Foundation
import TableProPluginKit

struct SnowflakeStatementGenerator {
    let qualifiedTable: String
    let columns: [String]
    let columnTypeNames: [String]
    let primaryKeyColumns: [String]

    // Snowflake does not enforce a primary key, so a key match can reach several rows too: every update and delete
    // first has to find exactly one.
    func rowWrites(
        from changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) throws -> [PluginRowWrite] {
        var writes: [PluginRowWrite] = []
        for change in changes {
            switch change.type {
            case .insert:
                guard insertedRowIndices.contains(change.rowIndex),
                      let statement = insertStatement(for: change, insertedRowData: insertedRowData) else { continue }
                writes.append(PluginRowWrite(statement: statement.statement, parameters: statement.parameters, rowIndices: [change.rowIndex]))
            case .update:
                guard !change.cellChanges.isEmpty else { continue }
                let condition = try whereClause(for: change)
                let expressions = change.expressionColumns ?? []
                var setClauses: [String] = []
                var parameters: [PluginCellValue] = []
                for cellChange in change.cellChanges {
                    let column = quoteIdentifier(cellChange.columnName)
                    if expressions.contains(cellChange.columnIndex), case .text(let sql) = cellChange.newValue {
                        setClauses.append("\(column) = \(sql)")
                    } else {
                        setClauses.append("\(column) = \(placeholder(for: cellChange.columnName))")
                        parameters.append(cellChange.newValue)
                    }
                }
                writes.append(PluginRowWrite(
                    statement: "UPDATE \(qualifiedTable) SET \(setClauses.joined(separator: ", ")) WHERE \(condition.sql)",
                    parameters: parameters + condition.parameters,
                    rowIndices: [change.rowIndex],
                    lookup: lookup(condition)
                ))
            case .delete:
                guard deletedRowIndices.contains(change.rowIndex) else { continue }
                let condition = try whereClause(for: change)
                writes.append(PluginRowWrite(
                    statement: "DELETE FROM \(qualifiedTable) WHERE \(condition.sql)",
                    parameters: condition.parameters,
                    rowIndices: [change.rowIndex],
                    lookup: lookup(condition)
                ))
            @unknown default:
                continue
            }
        }
        return writes
    }

    func restoreStatements(rows: [[PluginCellValue]]) -> [(statement: String, parameters: [PluginCellValue])] {
        rows.enumerated().compactMap { index, row in
            insertStatement(
                for: PluginRowChange(rowIndex: index, type: .insert, cellChanges: [], originalRow: nil),
                insertedRowData: [index: row]
            )
        }
    }

    private func lookup(_ condition: (sql: String, parameters: [PluginCellValue])) -> PluginRowLookup {
        PluginRowLookup(
            query: "SELECT 1 FROM \(qualifiedTable) WHERE \(condition.sql) LIMIT 2",
            parameters: condition.parameters,
            rowCount: 1,
            pinsRows: false
        )
    }

    /// What the grid stages for a column the user leaves to the server's default. It is a marker, never a value.
    static let defaultMarker = PluginCellValue.text("__DEFAULT__")

    static func isSemiStructured(_ typeName: String) -> Bool {
        let base = typeName.uppercased().components(separatedBy: "(")[0].trimmingCharacters(in: .whitespaces)
        return ["VARIANT", "OBJECT", "ARRAY"].contains(base)
    }

    private func insertStatement(
        for change: PluginRowChange,
        insertedRowData: [Int: [PluginCellValue]]
    ) -> (statement: String, parameters: [PluginCellValue])? {
        var values: [(column: String, value: PluginCellValue)] = []
        if let rowData = insertedRowData[change.rowIndex] {
            for (index, column) in columns.enumerated() where index < rowData.count {
                values.append((column, rowData[index]))
            }
        } else {
            for cellChange in change.cellChanges {
                values.append((cellChange.columnName, cellChange.newValue))
            }
        }
        guard !values.isEmpty else { return nil }
        let expressions = Set((change.expressionColumns ?? []).compactMap { columns.indices.contains($0) ? columns[$0] : nil })
        values.removeAll { $0.value == Self.defaultMarker }
        guard !values.isEmpty else {
            guard let firstColumn = columns.first else { return nil }
            return ("INSERT INTO \(qualifiedTable) (\(quoteIdentifier(firstColumn))) VALUES (DEFAULT)", [])
        }

        let names = values.map { quoteIdentifier($0.column) }
        let placeholders = values.map { value -> String in
            if expressions.contains(value.column), case .text(let sql) = value.value { return sql }
            return placeholder(for: value.column)
        }
        let parameters = values.filter { !expressions.contains($0.column) }.map(\.value)
        let usesSelect = values.contains { Self.isSemiStructured(typeName(for: $0.column)) }

        let statement = usesSelect
            ? "INSERT INTO \(qualifiedTable) (\(names.joined(separator: ", "))) SELECT \(placeholders.joined(separator: ", "))"
            : "INSERT INTO \(qualifiedTable) (\(names.joined(separator: ", "))) VALUES (\(placeholders.joined(separator: ", ")))"
        return (statement, parameters)
    }

    private func whereClause(for change: PluginRowChange) throws -> (sql: String, parameters: [PluginCellValue]) {
        let refusal = PluginRowWriteRefusal(
            rowIndex: change.rowIndex,
            reason: String(localized: "The row's loaded values are missing, so it cannot be found again.")
        )
        guard let originalRow = change.originalRow else { throw refusal }

        let keyColumns = primaryKeyColumns.isEmpty ? columns : primaryKeyColumns
        var conditions: [String] = []
        var parameters: [PluginCellValue] = []

        for column in keyColumns {
            // Leaving a column out of the match reaches every row that shares the rest.
            guard let index = columns.firstIndex(of: column), index < originalRow.count else { throw refusal }
            if Self.isSemiStructured(typeName(for: column)) { continue }
            let value = originalRow[index]
            if case .null = value {
                conditions.append("\(quoteIdentifier(column)) IS NULL")
            } else {
                conditions.append("\(quoteIdentifier(column)) = ?")
                parameters.append(value)
            }
        }

        guard !conditions.isEmpty else { throw refusal }
        return (conditions.joined(separator: " AND "), parameters)
    }

    private func typeName(for column: String) -> String {
        guard let index = columns.firstIndex(of: column), index < columnTypeNames.count else { return "TEXT" }
        return columnTypeNames[index]
    }

    private func placeholder(for column: String) -> String {
        Self.isSemiStructured(typeName(for: column)) ? "PARSE_JSON(?)" : "?"
    }

    private func quoteIdentifier(_ name: String) -> String {
        SnowflakeSQL.quoteIdentifier(name)
    }
}
