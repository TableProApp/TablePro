//
//  JSONExportPlugin.swift
//  JSONExportPlugin
//

import Foundation
import SwiftUI
import TableProPluginKit

@Observable
final class JSONExportPlugin: ExportFormatPlugin, SettablePlugin, @unchecked Sendable {
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

    var currentFileExtension: String {
        settings.layout.fileExtension
    }

    @MainActor
    func settingsView() -> AnyView? {
        AnyView(JSONExportOptionsView(plugin: self))
    }

    func resetSettingsToDefaults() {
        settings = JSONExportOptions()
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

        /// NDJSON is one row per line by definition, so the pretty-print setting cannot apply to it
        /// and the wrapping object has no place to go.
        let isNewlineDelimited = settings.layout == .newlineDelimited
        let prettyPrint = settings.prettyPrint && !isNewlineDelimited
        let indent = prettyPrint ? "  " : ""
        let newline = prettyPrint ? "\n" : ""

        if !isNewlineDelimited {
            try fileHandle.write(contentsOf: "{\(newline)".toUTF8Data())
        }

        var hasWrittenAnyRow = false
        for (tableIndex, table) in tables.enumerated() {
            try progress.checkCancellation()

            progress.setCurrentTable(table.qualifiedName, index: tableIndex + 1)

            let escapedTableName = PluginExportUtilities.escapeJSONString(table.qualifiedName)
            if !isNewlineDelimited {
                try fileHandle.write(contentsOf: "\(indent)\"\(escapedTableName)\": [\(newline)".toUTF8Data())
            }

            var hasWrittenRow = isNewlineDelimited ? hasWrittenAnyRow : false
            var columns: [String]?
            var columnTypeNames: [String]?

            let stream = dataSource.streamRows(for: table)
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
                            rowString += isNewlineDelimited ? "\n" : ",\(newline)"
                        }

                        rowString += rowPrefix
                        rowString += "{"

                        if let columns {
                            var isFirstField = true
                            for (colIndex, column) in columns.enumerated() {
                                if colIndex < row.count {
                                    let value = row[colIndex]
                                    if settings.includeNullValues || !value.isNull {
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
                        hasWrittenAnyRow = true
                        progress.incrementRow()
                    }
                }
            }

            if isNewlineDelimited {
                continue
            }
            if hasWrittenRow {
                try fileHandle.write(contentsOf: newline.toUTF8Data())
            }
            let tableSuffix = tableIndex < tables.count - 1 ? ",\(newline)" : newline
            try fileHandle.write(contentsOf: "\(indent)]\(tableSuffix)".toUTF8Data())
        }

        if isNewlineDelimited {
            if hasWrittenAnyRow {
                try fileHandle.write(contentsOf: "\n".toUTF8Data())
            }
        } else {
            try fileHandle.write(contentsOf: "}".toUTF8Data())
        }

        try progress.checkCancellation()
        try fileHandle.close()
        try PluginExportUtilities.commitAtomicWrite(from: tempURL, to: destination)
        committed = true
        progress.finalizeTable()
        return ExportFormatResult()
    }

    // MARK: - Private

    private func formatJSONValue(_ value: PluginCellValue, columnTypeName: String, preserveAsString: Bool) -> String {
        switch value {
        case .null:
            return "null"
        case .bytes(let data):
            return "\"\(data.base64EncodedString())\""
        case .text(let val):
            return formatJSONTextValue(val, columnTypeName: columnTypeName, preserveAsString: preserveAsString)
        }
    }

    private func formatJSONTextValue(_ val: String, columnTypeName: String, preserveAsString: Bool) -> String {
        if preserveAsString {
            return "\"\(PluginExportUtilities.escapeJSONString(val))\""
        }

        let folded = val.lowercased()
        if folded == "true" || folded == "false" {
            return folded
        }

        if PluginExportUtilities.isNumericColumnType(columnTypeName),
           let literal = JsonNumberNormalizer.numberLiteral(from: val) {
            return literal
        }

        return "\"\(PluginExportUtilities.escapeJSONString(val))\""
    }
}
