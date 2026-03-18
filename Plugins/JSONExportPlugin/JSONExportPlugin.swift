//
//  JSONExportPlugin.swift
//  JSONExportPlugin
//

import Foundation
import SwiftUI
import TableProPluginKit

@Observable
final class JSONExportPlugin: ExportFormatPlugin, SettablePlugin {
    static let pluginName = "JSON Export"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Export data to JSON format"
    static let formatId = "json"
    static let formatDisplayName = "JSON"
    static let defaultFileExtension = "json"
    static let iconName = "curlybraces"

    typealias Settings = JSONExportOptions
    static let settingsStorageId = "json"

    var settings = JSONExportOptions() {
        didSet { saveSettings() }
    }

    required init() { loadSettings() }

    func settingsView() -> AnyView? {
        AnyView(JSONExportOptionsView(plugin: self))
    }

    func export(
        tables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        destination: URL,
        progress: PluginExportProgress
    ) async throws {
        let fileHandle = try PluginExportUtilities.createFileHandle(at: destination)
        defer { try? fileHandle.close() }

        let prettyPrint = settings.prettyPrint
        let indent = prettyPrint ? "  " : ""
        let newline = prettyPrint ? "\n" : ""

        try fileHandle.write(contentsOf: "{\(newline)".toUTF8Data())

        for (tableIndex, table) in tables.enumerated() {
            try progress.checkCancellation()

            progress.setCurrentTable(table.qualifiedName, index: tableIndex + 1)

            let escapedTableName = PluginExportUtilities.escapeJSONString(table.qualifiedName)
            try fileHandle.write(contentsOf: "\(indent)\"\(escapedTableName)\": [\(newline)".toUTF8Data())

            let batchSize = 1_000
            var offset = 0
            var hasWrittenRow = false
            var columns: [String]?

            batchLoop: while true {
                try progress.checkCancellation()

                let result = try await dataSource.fetchRows(
                    table: table.name,
                    databaseName: table.databaseName,
                    offset: offset,
                    limit: batchSize
                )

                if result.rows.isEmpty { break batchLoop }

                if columns == nil {
                    columns = result.columns
                }

                for row in result.rows {
                    try progress.checkCancellation()

                    let rowPrefix = prettyPrint ? "\(indent)\(indent)" : ""
                    var rowString = ""

                    if hasWrittenRow {
                        rowString += ",\(newline)"
                    }

                    rowString += rowPrefix
                    rowString += "{"

                    if let columns {
                        var isFirstField = true
                        for (colIndex, column) in columns.enumerated() {
                            if colIndex < row.count {
                                let value = row[colIndex]
                                if settings.includeNullValues || value != nil {
                                    if !isFirstField {
                                        rowString += ", "
                                    }
                                    isFirstField = false

                                    let escapedKey = PluginExportUtilities.escapeJSONString(column)
                                    let jsonValue = formatJSONValue(
                                        value,
                                        preserveAsString: settings.preserveAllAsStrings
                                    )
                                    rowString += "\"\(escapedKey)\": \(jsonValue)"
                                }
                            }
                        }
                    }

                    rowString += "}"

                    try fileHandle.write(contentsOf: rowString.toUTF8Data())
                    hasWrittenRow = true
                    progress.incrementRow()
                }

                offset += result.rows.count
            }

            if hasWrittenRow {
                try fileHandle.write(contentsOf: newline.toUTF8Data())
            }
            let tableSuffix = tableIndex < tables.count - 1 ? ",\(newline)" : newline
            try fileHandle.write(contentsOf: "\(indent)]\(tableSuffix)".toUTF8Data())
        }

        try fileHandle.write(contentsOf: "}".toUTF8Data())

        try progress.checkCancellation()
        progress.finalizeTable()
    }

    // MARK: - Private

    private func formatJSONValue(_ value: String?, preserveAsString: Bool) -> String {
        guard let val = value else { return "null" }

        if preserveAsString {
            return "\"\(PluginExportUtilities.escapeJSONString(val))\""
        }

        if let intVal = Int(val) {
            return String(intVal)
        }
        if let doubleVal = Double(val), !val.contains("e") && !val.contains("E") {
            let jsMaxSafeInteger = 9_007_199_254_740_991.0

            if doubleVal.truncatingRemainder(dividingBy: 1) == 0 && !val.contains(".") {
                if abs(doubleVal) <= jsMaxSafeInteger,
                   doubleVal >= Double(Int.min),
                   doubleVal <= Double(Int.max) {
                    return String(Int(doubleVal))
                } else {
                    return val
                }
            }
            return String(doubleVal)
        }
        if val.lowercased() == "true" || val.lowercased() == "false" {
            return val.lowercased()
        }

        return "\"\(PluginExportUtilities.escapeJSONString(val))\""
    }
}
