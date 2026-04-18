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
    ) async throws -> ExportFormatResult {
        let (fileHandle, tempURL) = try PluginExportUtilities.beginAtomicWrite(for: destination)
        var committed = false
        defer {
            if !committed {
                PluginExportUtilities.rollbackAtomicWrite(at: tempURL)
            }
        }

        let prettyPrint = settings.prettyPrint
        let indent = prettyPrint ? "  " : ""
        let newline = prettyPrint ? "\n" : ""

        try fileHandle.write(contentsOf: "{\(newline)".toUTF8Data())

        for (tableIndex, table) in tables.enumerated() {
            try progress.checkCancellation()

            progress.setCurrentTable(table.qualifiedName, index: tableIndex + 1)

            let escapedTableName = PluginExportUtilities.escapeJSONString(table.qualifiedName)
            try fileHandle.write(contentsOf: "\(indent)\"\(escapedTableName)\": [\(newline)".toUTF8Data())

            var hasWrittenRow = false
            var columns: [String]?
            var columnTypeNames: [String]?

            let stream = dataSource.streamRows(table: table.name, databaseName: table.databaseName)
            for try await element in stream {
                try progress.checkCancellation()

                switch element {
                case .header(let header):
                    columns = header.columns
                    columnTypeNames = header.columnTypeNames
                case .rows(let rows):
                    for row in rows {
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
                                        let colTypeName = colIndex < (columnTypeNames ?? []).count
                                            ? (columnTypeNames ?? [])[colIndex]
                                            : ""
                                        let jsonValue = formatJSONValue(
                                            value,
                                            columnTypeName: colTypeName,
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
                }
            }

            if hasWrittenRow {
                try fileHandle.write(contentsOf: newline.toUTF8Data())
            }
            let tableSuffix = tableIndex < tables.count - 1 ? ",\(newline)" : newline
            try fileHandle.write(contentsOf: "\(indent)]\(tableSuffix)".toUTF8Data())
        }

        try fileHandle.write(contentsOf: "}".toUTF8Data())

        try progress.checkCancellation()
        try fileHandle.close()
        try PluginExportUtilities.commitAtomicWrite(from: tempURL, to: destination)
        committed = true
        progress.finalizeTable()
        return ExportFormatResult()
    }

    // MARK: - Private

    private func formatJSONValue(_ value: String?, columnTypeName: String, preserveAsString: Bool) -> String {
        guard let val = value else { return "null" }

        if preserveAsString {
            return "\"\(PluginExportUtilities.escapeJSONString(val))\""
        }

        if val.lowercased() == "true" || val.lowercased() == "false" {
            return val.lowercased()
        }

        let isNumericCol = isNumericColumnType(columnTypeName)

        if isNumericCol && isValidIntegerLiteral(val) {
            if let intVal = Int(val) {
                return String(intVal)
            }
            return val
        }
        if isNumericCol, let doubleVal = Double(val), !val.contains("e"), !val.contains("E") {
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

        return "\"\(PluginExportUtilities.escapeJSONString(val))\""
    }

    private func isNumericColumnType(_ typeName: String) -> Bool {
        let numericPrefixes = [
            "int", "bigint", "decimal", "float", "double", "numeric",
            "real", "smallint", "tinyint", "mediumint", "integer", "number"
        ]
        let lower = typeName.lowercased()
        return numericPrefixes.contains { lower.hasPrefix($0) }
    }

    private func isValidIntegerLiteral(_ val: String) -> Bool {
        guard !val.isEmpty else { return false }
        let digits = val.hasPrefix("-") || val.hasPrefix("+") ? String(val.dropFirst()) : val
        guard !digits.isEmpty else { return false }
        if digits.count > 1 && digits.hasPrefix("0") { return false }
        return digits.allSatisfy(\.isNumber)
    }
}
