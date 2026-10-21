//
//  QueryResultFiles.swift
//  TablePro
//

import AppIntents
import Foundation
import TableProPluginKit
import TableProTabularIO
import UniformTypeIdentifiers

// Shortcuts reads a JSON file as a Dictionary, so a row handed over as one becomes a dictionary keyed by column in
// the next action. App Intents has no dictionary value of its own.
internal enum QueryResultFiles {
    internal static func files(columns: [String], rows: [[PluginCellValue]], format: QueryResultFormat) -> [IntentFile] {
        switch format {
        case .rows:
            return rowObjects(columns: columns, rows: rows).enumerated().map { index, object in
                IntentFile(data: Data(object.utf8), filename: "row-\(index + 1).json", type: .json)
            }
        case .firstValue:
            guard let value = firstValue(rows: rows) else { return [] }
            return [IntentFile(data: Data(value.utf8), filename: "value.txt", type: .utf8PlainText)]
        case .csv:
            return [IntentFile(data: Data(csv(columns: columns, rows: rows).utf8), filename: "result.csv", type: .commaSeparatedText)]
        case .json:
            return [IntentFile(data: Data(jsonArray(columns: columns, rows: rows).utf8), filename: "result.json", type: .json)]
        }
    }

    internal static func rowObjects(columns: [String], rows: [[PluginCellValue]]) -> [String] {
        let keys = keys(for: columns).map(jsonString)
        return rows.map { row in
            let members = keys.enumerated().map { index, key in
                "\(key):\(index < row.count ? jsonValue(row[index]) : "null")"
            }
            return "{\(members.joined(separator: ","))}"
        }
    }

    internal static func jsonArray(columns: [String], rows: [[PluginCellValue]]) -> String {
        "[\(rowObjects(columns: columns, rows: rows).joined(separator: ","))]"
    }

    internal static func csv(columns: [String], rows: [[PluginCellValue]]) -> String {
        let writer = DelimitedWriter(dialect: DelimitedDialect(), source: nil)
        let lines = [columns] + rows.map { row in row.map(ScriptResultEncoder.text(of:)) }
        return lines.map { fields in fields.map(writer.quoted).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    internal static func firstValue(rows: [[PluginCellValue]]) -> String? {
        guard let cell = rows.first?.first else { return nil }
        if case .null = cell { return nil }
        return ScriptResultEncoder.text(of: cell)
    }

    // Two columns of one name would collapse into one key, so a repeat takes a numbered name.
    internal static func keys(for columns: [String]) -> [String] {
        ImportFieldNaming.uniqueNames(for: columns) { "column \($0 + 1)" }
    }

    private static func jsonValue(_ cell: PluginCellValue) -> String {
        switch cell {
        case .null: "null"
        case .text, .bytes: jsonString(ScriptResultEncoder.text(of: cell))
        }
    }

    private static func jsonString(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
              let encoded = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return encoded
    }
}
