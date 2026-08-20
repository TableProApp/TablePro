import Foundation
import TableProPluginKit
import TableProTeradataCore

extension TeradataPluginDriver {
    func sqlLiteral(_ value: PluginCellValue) -> String {
        switch value {
        case .null:
            return "NULL"
        case .text(let string):
            return "'" + string.replacingOccurrences(of: "'", with: "''") + "'"
        case .bytes(let data):
            return "'" + data.map { String(format: "%02X", $0) }.joined() + "'XB"
        }
    }

    func generateStatements(
        table: String, columns: [String], primaryKeyColumns: [String],
        changes: [PluginRowChange], insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>, insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        generateStatements(
            table: table, schema: nil, columns: columns, primaryKeyColumns: primaryKeyColumns,
            changes: changes, insertedRowData: insertedRowData,
            deletedRowIndices: deletedRowIndices, insertedRowIndices: insertedRowIndices)
    }

    func generateStatements(
        table: String, schema: String?, columns: [String], primaryKeyColumns: [String],
        changes: [PluginRowChange], insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>, insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        let target = TeradataSchemaQueries.qualifiedName(
            database: effectiveDatabaseForSchema(schema), table: table)
        var statements: [(statement: String, parameters: [PluginCellValue])] = []

        for change in changes {
            switch change.type {
            case .insert:
                guard insertedRowIndices.contains(change.rowIndex),
                      let values = insertedRowData[change.rowIndex], values.count == columns.count else { continue }
                let columnList = columns.map(quote).joined(separator: ", ")
                let valueList = values.map(sqlLiteral).joined(separator: ", ")
                statements.append(("INSERT INTO \(target) (\(columnList)) VALUES (\(valueList))", []))
            case .update:
                let assignments = change.cellChanges.map { "\(quote($0.columnName)) = \(sqlLiteral($0.newValue))" }
                guard !assignments.isEmpty else { continue }
                let whereClause = keyPredicate(primaryKeyColumns, columns: columns, change: change)
                statements.append(("UPDATE \(target) SET \(assignments.joined(separator: ", "))\(whereClause)", []))
            case .delete:
                guard deletedRowIndices.contains(change.rowIndex) else { continue }
                let whereClause = keyPredicate(primaryKeyColumns, columns: columns, change: change)
                statements.append(("DELETE FROM \(target)\(whereClause)", []))
            }
        }
        return statements.isEmpty ? nil : statements
    }

    private func quote(_ name: String) -> String {
        TeradataSchemaQueries.quoteIdentifier(name)
    }

    private func effectiveDatabaseForSchema(_ schema: String?) -> String? {
        if let schema, !schema.isEmpty { return schema }
        return currentDatabaseName
    }

    private func keyPredicate(_ primaryKeyColumns: [String], columns: [String], change: PluginRowChange) -> String {
        let keyColumns = primaryKeyColumns.isEmpty ? columns : primaryKeyColumns
        let conditions = keyColumns.map { column -> String in
            let value = oldValue(for: column, columns: columns, change: change)
            if case .null = value { return "\(quote(column)) IS NULL" }
            return "\(quote(column)) = \(sqlLiteral(value))"
        }
        return conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
    }

    private func oldValue(for column: String, columns: [String], change: PluginRowChange) -> PluginCellValue {
        if let originalRow = change.originalRow,
           let index = columns.firstIndex(of: column), index < originalRow.count {
            return originalRow[index]
        }
        if let cell = change.cellChanges.first(where: { $0.columnName == column }) {
            return cell.oldValue
        }
        return .null
    }
}
