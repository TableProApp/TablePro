import Foundation
import TableProPluginKit

enum DataGridEditValue: Equatable {
    case enteredText(String?)
    case value(PluginCellValue, isExpression: Bool)
    case removeField
}

struct DataGridCellEdit: Equatable {
    let rowID: RowID
    let columnID: DataGridColumnID
    let value: DataGridEditValue
}

struct DataGridResolvedEdit: Equatable {
    let rowID: RowID
    let dataIndex: Int
    let columnName: String
    let oldValue: PluginCellValue
    let newValue: PluginCellValue
    let originalRow: [PluginCellValue]
    let absence: FieldAbsence
    let isExpression: Bool
}
