//
//  CellEntry.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Nil keeps the caller on its literal path, which an older plugin still reads its own way.
enum CellEntry {
    static func typed(
        _ text: String,
        columnType: ColumnType?,
        databaseType: DatabaseType,
        writer: CellWriterSupport
    ) -> (value: PluginCellValue, isExpression: Bool)? {
        guard writer.acceptsExpressions,
              let expression = CellExpressionVocabulary.expression(
                  typed: text, databaseType: databaseType, columnType: columnType
              ) else { return nil }
        return (value: PluginCellValue.text(expression.sql), isExpression: true)
    }
}
