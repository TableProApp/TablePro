import Foundation
import TableProModels
import UIKit

enum ExportFormat: String, CaseIterable, Identifiable {
    case json = "JSON"
    case csv = "CSV"
    case sqlInsert = "SQL INSERT"
    var id: String { rawValue }
}

enum ClipboardExporter {
    static func exportRow(columns: [ColumnInfo], row: [String?], format: ExportFormat, tableName: String? = nil) -> String {
        switch format {
        case .json:
            return rowToJson(columns: columns, row: row)
        case .csv:
            return rowToCsv(columns: columns, row: row, includeHeader: true)
        case .sqlInsert:
            return rowToInsert(columns: columns, row: row, tableName: tableName ?? "table")
        }
    }

    static func exportRows(columns: [ColumnInfo], rows: [[String?]], format: ExportFormat, tableName: String? = nil) -> String {
        switch format {
        case .json:
            let objects = rows.map { rowToJson(columns: columns, row: $0) }
            return "[\n" + objects.joined(separator: ",\n") + "\n]"
        case .csv:
            let header = columns.map { escapeCsvField($0.name) }.joined(separator: ",")
            let dataLines = rows.map { row in
                columns.indices.map { i in
                    escapeCsvField(i < row.count ? row[i] ?? "NULL" : "NULL")
                }.joined(separator: ",")
            }
            return ([header] + dataLines).joined(separator: "\n")
        case .sqlInsert:
            let name = tableName ?? "table"
            return rows.map { rowToInsert(columns: columns, row: $0, tableName: name) }.joined(separator: "\n")
        }
    }

    static func copyToClipboard(_ text: String) {
        UIPasteboard.general.string = text
    }

    // MARK: - Private

    private static func rowToJson(columns: [ColumnInfo], row: [String?]) -> String {
        var pairs: [String] = []
        for (i, col) in columns.enumerated() {
            let value = i < row.count ? row[i] : nil
            let key = "  \"\(escapeJsonString(col.name))\""
            if let value {
                if Int64(value) != nil {
                    pairs.append("\(key): \(value)")
                } else if let parsed = Double(value), parsed.isFinite {
                    pairs.append("\(key): \(value)")
                } else if value == "true" || value == "false" {
                    pairs.append("\(key): \(value)")
                } else {
                    pairs.append("\(key): \"\(escapeJsonString(value))\"")
                }
            } else {
                pairs.append("\(key): null")
            }
        }
        return "{\n" + pairs.joined(separator: ",\n") + "\n}"
    }

    private static func rowToCsv(columns: [ColumnInfo], row: [String?], includeHeader: Bool) -> String {
        var lines: [String] = []
        if includeHeader {
            lines.append(columns.map { escapeCsvField($0.name) }.joined(separator: ","))
        }
        let dataLine = columns.indices.map { i in
            escapeCsvField(i < row.count ? row[i] ?? "NULL" : "NULL")
        }.joined(separator: ",")
        lines.append(dataLine)
        return lines.joined(separator: "\n")
    }

    private static func rowToInsert(columns: [ColumnInfo], row: [String?], tableName: String) -> String {
        let cols = columns.map { "\"\($0.name)\"" }.joined(separator: ", ")
        let vals = columns.indices.map { i in
            let value = i < row.count ? row[i] : nil
            guard let value else { return "NULL" }
            return "'\(value.replacingOccurrences(of: "'", with: "''"))'"
        }.joined(separator: ", ")
        return "INSERT INTO \"\(tableName)\" (\(cols)) VALUES (\(vals));"
    }

    private static func escapeCsvField(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    private static func escapeJsonString(_ str: String) -> String {
        str.replacingOccurrences(of: "\\", with: "\\\\")
           .replacingOccurrences(of: "\"", with: "\\\"")
           .replacingOccurrences(of: "\n", with: "\\n")
           .replacingOccurrences(of: "\r", with: "\\r")
           .replacingOccurrences(of: "\t", with: "\\t")
    }
}
