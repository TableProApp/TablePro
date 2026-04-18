//
//  CSVExportPlugin.swift
//  CSVExportPlugin
//

import Foundation
import SwiftUI
import TableProPluginKit

@Observable
final class CSVExportPlugin: ExportFormatPlugin, SettablePlugin {
    static let pluginName = "CSV Export"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Export data to CSV format"
    static let formatId = "csv"
    static let formatDisplayName = "CSV"
    static let defaultFileExtension = "csv"
    static let iconName = "doc.text"

    // swiftlint:disable:next force_try
    static let decimalFormatRegex = try! NSRegularExpression(pattern: #"^[+-]?\d+\.\d+$"#)

    typealias Settings = CSVExportOptions
    static let settingsStorageId = "csv"

    var settings = CSVExportOptions() {
        didSet { saveSettings() }
    }

    required init() { loadSettings() }

    func settingsView() -> AnyView? {
        AnyView(CSVExportOptionsView(plugin: self))
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

        let lineBreak = settings.lineBreak.value

        for (index, table) in tables.enumerated() {
            try progress.checkCancellation()

            progress.setCurrentTable(table.qualifiedName, index: index + 1)

            if tables.count > 1 {
                let sanitizedName = PluginExportUtilities.sanitizeForSQLComment(table.qualifiedName)
                try fileHandle.write(contentsOf: "# Table: \(sanitizedName)\n".toUTF8Data())
            }

            var isFirstBatch = true
            var columns: [String] = []

            let stream = dataSource.streamRows(table: table.name, databaseName: table.databaseName)
            for try await element in stream {
                try progress.checkCancellation()

                switch element {
                case .header(let header):
                    columns = header.columns
                    if isFirstBatch && settings.includeFieldNames {
                        let headerLine = columns
                            .map { escapeCSVField($0, options: settings) }
                            .joined(separator: settings.delimiter.actualValue)
                        try fileHandle.write(contentsOf: (headerLine + lineBreak).toUTF8Data())
                    }
                    isFirstBatch = false
                case .rows(let rows):
                    for row in rows {
                        try writeCSVRow(row, options: settings, to: fileHandle)
                        progress.incrementRow()
                    }
                }
            }

            if index < tables.count - 1 {
                try fileHandle.write(contentsOf: "\(lineBreak)\(lineBreak)".toUTF8Data())
            }
        }

        try progress.checkCancellation()
        try fileHandle.close()
        try PluginExportUtilities.commitAtomicWrite(from: tempURL, to: destination)
        committed = true
        progress.finalizeTable()
        return ExportFormatResult()
    }

    // MARK: - Private

    private func writeCSVRow(
        _ row: [String?],
        options: CSVExportOptions,
        to fileHandle: FileHandle
    ) throws {
        let delimiter = options.delimiter.actualValue
        let lineBreak = options.lineBreak.value

        let rowLine = row.map { value -> String in
            guard let val = value else {
                return options.convertNullToEmpty ? "" : "NULL"
            }

            var processed = val
            let hadLineBreaks = val.contains("\n") || val.contains("\r")

            if options.convertLineBreakToSpace {
                processed = processed
                    .replacingOccurrences(of: "\r\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
            }

            if options.decimalFormat == .comma {
                let range = NSRange(processed.startIndex..., in: processed)
                if Self.decimalFormatRegex.firstMatch(in: processed, range: range) != nil {
                    processed = processed.replacingOccurrences(of: ".", with: ",")
                }
            }

            return escapeCSVField(processed, options: options, originalHadLineBreaks: hadLineBreaks)
        }.joined(separator: delimiter)

        try fileHandle.write(contentsOf: (rowLine + lineBreak).toUTF8Data())
    }

    private func escapeCSVField(_ field: String, options: CSVExportOptions, originalHadLineBreaks: Bool = false) -> String {
        var processed = field

        if options.sanitizeFormulas {
            let dangerousPrefixes: [Character] = ["=", "+", "-", "@"]
            if let first = processed.first, dangerousPrefixes.contains(first) {
                processed = "'" + processed
            }
        }

        switch options.quoteHandling {
        case .always:
            let escaped = processed.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        case .never:
            return processed
        case .asNeeded:
            let needsQuotes = processed.contains(options.delimiter.actualValue) ||
                processed.contains("\"") ||
                processed.contains("\n") ||
                processed.contains("\r") ||
                originalHadLineBreaks
            if needsQuotes {
                let escaped = processed.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\""
            }
            return processed
        }
    }
}
