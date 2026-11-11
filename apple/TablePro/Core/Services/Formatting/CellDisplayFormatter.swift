//
//  CellDisplayFormatter.swift
//  TablePro
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
        resolve(rawValue, columnType: columnType, displayFormat: displayFormat, databaseType: databaseType, checksRendering: false).text
    }

    static func display(
        _ rawValue: PluginCellValue,
        columnType: ColumnType?,
        displayFormat: ValueDisplayFormat?,
        databaseType: DatabaseType?
    ) -> (text: String?, isFormatted: Bool) {
        resolve(rawValue, columnType: columnType, displayFormat: displayFormat, databaseType: databaseType, checksRendering: true)
    }

    // Find, the value filter and the display order discard the flag, and the JSON and PHP checks read the whole value.
    private static func resolve(
        _ rawValue: PluginCellValue,
        columnType: ColumnType?,
        displayFormat: ValueDisplayFormat?,
        databaseType: DatabaseType?,
        checksRendering: Bool
    ) -> (text: String?, isFormatted: Bool) {
        switch rawValue {
        case .null:
            return (nil, false)
        case .bytes(let data):
            if let displayFormat,
               displayFormat.isApplicable(to: columnType, databaseType: databaseType),
               let formatted = ValueDisplayFormatter.apply(data, format: displayFormat, columnType: columnType) {
                return (fitToCell(formatted), true)
            }
            return (BlobFormattingService.shared.format(data, for: .grid), false)
        case .text(let value):
            guard !value.isEmpty else { return (value, false) }
            if let displayFormat, displayFormat != .raw,
               displayFormat.isApplicable(to: columnType, databaseType: databaseType),
               let formatted = ValueDisplayFormatter.apply(value, format: displayFormat, columnType: columnType) {
                return (fitToCell(formatted), checksRendering && rendered(formatted, from: value, by: displayFormat))
            }
            var displayValue = value
            if let columnType {
                if columnType.isDateType {
                    if let formatted = DateFormattingService.shared.format(
                        dateString: displayValue,
                        columnType: columnType
                    ) {
                        displayValue = formatted
                    }
                } else if columnType.isVectorType {
                    displayValue = VectorLiteral.summary(of: displayValue) ?? displayValue
                } else if BlobFormattingService.shared.requiresFormatting(columnType: columnType) {
                    displayValue = BlobFormattingService.shared.formatIfNeeded(
                        displayValue, columnType: columnType, for: .grid
                    )
                }
            }
            return (fitToCell(displayValue), false)
        }
    }

    // The UUID, timestamp, JSON and PHP formats hand back a text value they cannot read unchanged rather than nil.
    private static func rendered(_ formatted: String, from value: String, by format: ValueDisplayFormat) -> Bool {
        switch format {
        case .uuid, .uuidSwappedTime:
            return UUID(uuidString: formatted) != nil
        case .unixTimestamp, .unixTimestampMillis:
            return formatted != value
        case .json:
            return value.isValidJson
        case .phpSerialized:
            return CellValueContentDetector.detect(value) == .phpSerialized
        case .raw, .text, .messagePack, .protobuf, .igbinary, .avro, .protobufSchema, .schemaRegistry:
            return true
        }
    }

    // Binary read as text carries newlines and runs to megabytes, so all output is capped and flattened. A lone CR stays for the cell to mark.
    private static func fitToCell(_ value: String) -> String {
        var displayValue = value
        let nsDisplay = displayValue as NSString
        if nsDisplay.length > maxDisplayLength {
            displayValue = nsDisplay.substring(to: maxDisplayLength) + "…"
        }
        return displayValue.flattenedForCell
    }
}
