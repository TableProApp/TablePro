import Foundation
import TableProPluginKit
import TableProTrinoCore

extension TrinoPluginDriver {
    func generateStatements(
        table: String,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        generateStatements(
            table: table, schema: nil, columns: columns, primaryKeyColumns: primaryKeyColumns,
            changes: changes, insertedRowData: insertedRowData,
            deletedRowIndices: deletedRowIndices, insertedRowIndices: insertedRowIndices
        )
    }

    func generateStatements(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        let target = qualifiedName(table: table, schema: schema)
        let types = cachedColumnTypes(key: columnTypeKey(schema: schema, table: table))
        let typeName: (String) -> String = { types[$0] ?? "varchar" }

        var statements: [(statement: String, parameters: [PluginCellValue])] = []
        for change in changes {
            switch change.type {
            case .insert:
                guard insertedRowIndices.contains(change.rowIndex) else { continue }
                let values = TrinoRowEditValues.insertValues(
                    change, columns: columns, insertedRowData: insertedRowData, typeName: typeName
                )
                if let sql = TrinoRowEditSQL.insert(qualifiedTable: target, columns: values) {
                    statements.append((sql, []))
                }
            case .update:
                let assignments = change.cellChanges.map {
                    TrinoColumnValue(name: $0.columnName, value: TrinoRowEditValues.trinoValue($0.newValue), typeName: typeName($0.columnName))
                }
                guard let keys = keyColumns(primaryKeyColumns, columns: columns, change: change, typeName: typeName),
                      let sql = TrinoRowEditSQL.update(qualifiedTable: target, assignments: assignments, keyColumns: keys)
                else { continue }
                statements.append((sql, []))
            case .delete:
                guard deletedRowIndices.contains(change.rowIndex) else { continue }
                guard let keys = keyColumns(primaryKeyColumns, columns: columns, change: change, typeName: typeName),
                      let sql = TrinoRowEditSQL.delete(qualifiedTable: target, keyColumns: keys)
                else { continue }
                statements.append((sql, []))
            }
        }
        return statements.isEmpty ? nil : statements
    }

    private func keyColumns(
        _ primaryKeyColumns: [String],
        columns: [String],
        change: PluginRowChange,
        typeName: (String) -> String
    ) -> [TrinoColumnValue]? {
        let keyNames = primaryKeyColumns.isEmpty ? columns : primaryKeyColumns
        var keys: [TrinoColumnValue] = []
        for column in keyNames {
            // Leaving a column out of the match reaches every row that shares the rest.
            guard let value = originalValue(column, columns: columns, change: change) else { return nil }
            keys.append(TrinoColumnValue(name: column, value: TrinoRowEditValues.trinoValue(value), typeName: typeName(column)))
        }
        return keys
    }

    private func originalValue(_ column: String, columns: [String], change: PluginRowChange) -> PluginCellValue? {
        if let originalRow = change.originalRow, let index = columns.firstIndex(of: column), index < originalRow.count {
            return originalRow[index]
        }
        return change.cellChanges.first { $0.columnName == column }?.oldValue
    }
}
