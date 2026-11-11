//
//  TrinoRowEditValues.swift
//  TrinoDriverPlugin
//

import Foundation
import TableProPluginKit
import TableProTrinoCore

/// The column values a grid change writes, in the form `TrinoRowEditSQL` renders.
enum TrinoRowEditValues {
    // Trino has no `DEFAULT` keyword in `VALUES`, so a defaulted column stays out of the insert and the connector fills it.
    static func insertValues(
        _ change: PluginRowChange,
        columns: [String],
        insertedRowData: [Int: [PluginCellValue]],
        typeName: (String) -> String
    ) -> [TrinoColumnValue] {
        if let rowData = insertedRowData[change.rowIndex] {
            return columns.enumerated().compactMap { index, column in
                guard index < rowData.count, !change.isColumnDefault(index) else { return nil }
                return TrinoColumnValue(name: column, value: trinoValue(rowData[index]), typeName: typeName(column))
            }
        }
        return change.cellChanges.filter { !change.isColumnDefault($0.columnIndex) }.map {
            TrinoColumnValue(name: $0.columnName, value: trinoValue($0.newValue), typeName: typeName($0.columnName))
        }
    }

    static func writing(_ value: TrinoColumnValue, asExpression: Bool) -> TrinoColumnValue {
        guard asExpression, case .text(let sql) = value.value else { return value }
        return TrinoColumnValue(name: value.name, value: value.value, typeName: value.typeName, expression: sql)
    }

    static func trinoValue(_ cell: PluginCellValue) -> TrinoValue {
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
