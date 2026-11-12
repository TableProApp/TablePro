//
//  CsvRowConverter.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal struct CsvRowConverter {
    internal let columns: [String]
    internal let columnTypes: [ColumnType]

    private static let maxRows = 50_000

    func generateCsv(rows: [[PluginCellValue]], includeHeaders: Bool) -> String {
        let cappedRows = rows.prefix(Self.maxRows)
        let columnCount = columns.count

        var result = String()
        result.reserveCapacity(cappedRows.count * columnCount * 16)

        if includeHeaders {
            for (idx, header) in columns.enumerated() {
                if idx > 0 { result.append(",") }
                result.append(Self.encode(header))
            }
            result.append("\n")
        }

        for row in cappedRows {
            for idx in 0..<columnCount {
                if idx > 0 { result.append(",") }
                guard row.indices.contains(idx) else { continue }

                let columnType = columnTypes.indices.contains(idx) ? columnTypes[idx] : nil
                guard let text = RowValueCopyFormatter.copyText(cell: row[idx], columnType: columnType) else {
                    continue
                }
                result.append(Self.encode(text))
            }
            result.append("\n")
        }

        return result
    }

    // An unquoted field holds no quote, so wrapping it for its edge spaces needs no escaping.
    static func encode(_ value: String) -> String {
        encode(value, options: fieldOptions)
    }

    // For a file the user opens in a spreadsheet, where a field another program wrote must not run as a formula.
    static func encodeForSpreadsheet(_ value: String) -> String {
        encode(value, options: spreadsheetFieldOptions)
    }

    private static func encode(_ value: String, options: PluginCsvWriteOptions) -> String {
        let field = PluginRowWriters.csvField(value, options: options)
        guard field.unicodeScalars.first != "\"", value.hasPrefix(" ") || value.hasSuffix(" ") else { return field }
        return "\"\(field)\""
    }

    private static let fieldOptions = PluginCsvWriteOptions(sanitizesFormulas: false)
    private static let spreadsheetFieldOptions = PluginCsvWriteOptions(sanitizesFormulas: true)
}
