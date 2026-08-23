//
//  CellDisplayFormatter.swift
//  TablePro
//
//  Pure formatter that transforms raw cell values into display-ready strings.
//  Used by the data grid coordinator's display cache to compute values once per cell.
//

import Foundation
import TableProPluginKit

@MainActor
enum CellDisplayFormatter {
    static let maxDisplayLength = 10_000

    static func format(
        _ rawValue: PluginCellValue,
        columnType: ColumnType?,
        displayFormat: ValueDisplayFormat? = nil,
        databaseType: DatabaseType? = nil
    ) -> String? {
        switch rawValue {
        case .null:
            return nil
        case .bytes(let data):
            if let displayFormat,
               displayFormat.isApplicable(to: columnType, databaseType: databaseType),
               let formatted = ValueDisplayFormatService.applyFormat(data, format: displayFormat) {
                return formatted
            }
            return BlobFormattingService.shared.format(data, for: .grid)
        case .text(let value):
            guard !value.isEmpty else { return value }
            var displayValue = value
            if let displayFormat, displayFormat != .raw,
               displayFormat.isApplicable(to: columnType, databaseType: databaseType) {
                displayValue = ValueDisplayFormatService.applyFormat(value, format: displayFormat)
            } else if let columnType {
                if columnType.isDateType {
                    if let formatted = DateFormattingService.shared.format(
                        dateString: displayValue,
                        columnType: columnType
                    ) {
                        displayValue = formatted
                    }
                } else if BlobFormattingService.shared.requiresFormatting(columnType: columnType) {
                    displayValue = BlobFormattingService.shared.formatIfNeeded(
                        displayValue, columnType: columnType, for: .grid
                    )
                }
            }
            let nsDisplay = displayValue as NSString
            if nsDisplay.length > maxDisplayLength {
                displayValue = nsDisplay.substring(to: maxDisplayLength) + "…"
            }
            return displayValue.sanitizedForCellDisplay
        }
    }
}
