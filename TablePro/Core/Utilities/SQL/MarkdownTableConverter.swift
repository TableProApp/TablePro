//
//  MarkdownTableConverter.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal struct MarkdownTableConverter {
    internal let columns: [String]
    internal let columnTypes: [ColumnType]

    private static let maxRows = 50_000

    func generateMarkdown(rows: [[PluginCellValue]]) -> String {
        let cappedRows = rows.prefix(Self.maxRows)
        let columnCount = columns.count
        guard columnCount > 0 else { return "" }

        var result = String()
        result.reserveCapacity(cappedRows.count * columnCount * 16)

        result.append("| ")
        result.append(columns.map(Self.encode).joined(separator: " | "))
        result.append(" |\n")

        result.append("|")
        for _ in 0..<columnCount {
            result.append(" --- |")
        }
        result.append("\n")

        for row in cappedRows {
            result.append("| ")
            for idx in 0..<columnCount {
                if idx > 0 { result.append(" | ") }

                guard row.indices.contains(idx) else {
                    result.append("NULL")
                    continue
                }

                let cell = row[idx]
                switch cell {
                case .null:
                    result.append("NULL")
                case .text(let value):
                    let columnType = columnTypes.indices.contains(idx) ? columnTypes[idx] : nil
                    let formatted = (columnType?.isBlobType ?? false)
                        ? (value.formattedAsCompactHex() ?? value)
                        : value
                    result.append(Self.encode(formatted))
                case .bytes(let data):
                    let blob = String(data: data, encoding: .isoLatin1)?.formattedAsCompactHex() ?? ""
                    result.append(Self.encode(blob))
                }
            }
            result.append(" |\n")
        }

        return result
    }

    static func encode(_ value: String) -> String {
        var result = String()
        result.reserveCapacity((value as NSString).length)

        for scalar in value.unicodeScalars {
            switch scalar {
            case "|":
                result.append("\\|")
            case "\n", "\r":
                result.append("<br>")
            default:
                result.append(Character(scalar))
            }
        }

        return result
    }
}
