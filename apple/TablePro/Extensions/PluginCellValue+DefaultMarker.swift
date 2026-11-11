//
//  PluginCellValue+DefaultMarker.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal extension PluginCellValue {
    // A cell left to the column's default is the SQL keyword, marked as SQL beside the value like any expression. The
    // mark decides, never the text: a stored or typed value can read the same.
    static let columnDefaultKeyword = "DEFAULT"
    static let columnDefault = PluginCellValue.text(columnDefaultKeyword)

    // The spelling driver plugins read as the default in the rows the host hands them.
    static let pluginDefaultMarker = PluginCellValue.text("__DEFAULT__")

    func isColumnDefault(isExpression: Bool) -> Bool {
        isExpression && self == Self.columnDefault
    }
}
