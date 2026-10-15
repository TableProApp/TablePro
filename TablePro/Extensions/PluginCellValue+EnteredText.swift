//
//  PluginCellValue+EnteredText.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal extension PluginCellValue {
    /// What text entered for a column means as a value.
    ///
    /// Emptying a cell whose type has no empty value asks for no value, which is NULL. Writing `''`
    /// there turned a cleared `deleted_at` into `0000-00-00 00:00:00` on MySQL, so the row still
    /// read as deleted. A text column keeps `''`, which is a real value there.
    static func entered(_ text: String?, columnType: ColumnType?) -> PluginCellValue {
        guard let text else { return .null }
        guard text.isEmpty, let columnType, !columnType.hasEmptyValue else { return .text(text) }
        return .null
    }
}
