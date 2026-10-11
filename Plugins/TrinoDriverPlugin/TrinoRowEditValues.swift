//
//  TrinoRowEditValues.swift
//  TrinoDriverPlugin
//

import Foundation
import TableProPluginKit
import TableProTrinoCore

/// The column values a grid change writes, in the form `TrinoRowEditSQL` renders.
enum TrinoRowEditValues {
    /// What the grid stages for a column the user leaves to the server's default. Trino has no `DEFAULT` keyword in
    /// `VALUES`, so the column stays out of the insert and the connector fills it.
    static let defaultMarker = PluginCellValue.text("__DEFAULT__")

    static func insertValues(
        _ change: PluginRowChange,
        columns: [String],
        insertedRowData: [Int: [PluginCellValue]],
        typeName: (String) -> String
    ) -> [TrinoColumnValue] {
        if let rowData = insertedRowData[change.rowIndex] {
            return columns.enumerated().compactMap { index, column in
                guard index < rowData.count, rowData[index] != defaultMarker else { return nil }
                return TrinoColumnValue(name: column, value: trinoValue(rowData[index]), typeName: typeName(column))
            }
        }
        return change.cellChanges.filter { $0.newValue != defaultMarker }.map {
            TrinoColumnValue(name: $0.columnName, value: trinoValue($0.newValue), typeName: typeName($0.columnName))
        }
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
