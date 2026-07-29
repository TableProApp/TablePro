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
                let values = insertValues(change, columns: columns, insertedRowData: insertedRowData, typeName: typeName)
                if let sql = TrinoRowEditSQL.insert(qualifiedTable: target, columns: values) {
                    statements.append((sql, []))
                }
            case .update:
                let assignments = change.cellChanges.map {
                    TrinoColumnValue(name: $0.columnName, value: Self.trinoValue($0.newValue), typeName: typeName($0.columnName))
                }
                let keys = keyColumns(primaryKeyColumns, columns: columns, change: change, typeName: typeName)
                if let sql = TrinoRowEditSQL.update(qualifiedTable: target, assignments: assignments, keyColumns: keys) {
                    statements.append((sql, []))
                }
            case .delete:
                guard deletedRowIndices.contains(change.rowIndex) else { continue }
                let keys = keyColumns(primaryKeyColumns, columns: columns, change: change, typeName: typeName)
                if let sql = TrinoRowEditSQL.delete(qualifiedTable: target, keyColumns: keys) {
                    statements.append((sql, []))
                }
            }
        }
        return statements.isEmpty ? nil : statements
    }

    private func insertValues(
        _ change: PluginRowChange,
        columns: [String],
        insertedRowData: [Int: [PluginCellValue]],
        typeName: (String) -> String
    ) -> [TrinoColumnValue] {
        if let rowData = insertedRowData[change.rowIndex] {
            return columns.enumerated().compactMap { index, column in
                guard index < rowData.count else { return nil }
                return TrinoColumnValue(name: column, value: Self.trinoValue(rowData[index]), typeName: typeName(column))
            }
        }
        return change.cellChanges.map {
            TrinoColumnValue(name: $0.columnName, value: Self.trinoValue($0.newValue), typeName: typeName($0.columnName))
        }
    }

    private func keyColumns(
        _ primaryKeyColumns: [String],
        columns: [String],
        change: PluginRowChange,
        typeName: (String) -> String
    ) -> [TrinoColumnValue] {
        let keyNames = primaryKeyColumns.isEmpty ? columns : primaryKeyColumns
        return keyNames.compactMap { column in
            guard let value = originalValue(column, columns: columns, change: change) else { return nil }
            return TrinoColumnValue(name: column, value: Self.trinoValue(value), typeName: typeName(column))
        }
    }

    private func originalValue(_ column: String, columns: [String], change: PluginRowChange) -> PluginCellValue? {
        if let originalRow = change.originalRow, let index = columns.firstIndex(of: column), index < originalRow.count {
            return originalRow[index]
        }
        return change.cellChanges.first { $0.columnName == column }?.oldValue
    }

    private static func trinoValue(_ cell: PluginCellValue) -> TrinoValue {
        switch cell {
        case .null:
            return .null
        case .text(let text):
            return .text(text)
        case .bytes(let data):
            return .bytes([UInt8](data))
        }
    }
}
