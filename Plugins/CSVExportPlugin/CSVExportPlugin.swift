//
//  CSVExportPlugin.swift
//  CSVExportPlugin
//

import Foundation
import SwiftUI
import TableProPluginKit

@Observable
final class CSVExportPlugin: ExportFormatPlugin, SettablePlugin, @unchecked Sendable {
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

    @MainActor
    func settingsView() -> AnyView? {
        AnyView(CSVExportOptionsView(plugin: self))
    }

    func resetSettingsToDefaults() {
        settings = CSVExportOptions()
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
        _ row: [PluginCellValue],
        options: CSVExportOptions,
        to fileHandle: FileHandle
    ) throws {
        let delimiter = options.delimiter.actualValue
        let lineBreak = options.lineBreak.value

        let rowLine = row.map { cell -> String in
            let val: String
            switch cell {
            case .null:
                return options.convertNullToEmpty ? "" : "NULL"
            case .text(let s):
                val = s
            case .bytes(let d):
                val = "0x" + d.map { String(format: "%02X", $0) }.joined()
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

    /// Escaping and quoting live in `PluginRowWriters`, so this format, the other export formats
    /// and the MCP tool spell a value the same way. Only the option mapping is this plugin's own.
    ///
    /// `originalHadLineBreaks` says the value's breaks were already replaced with spaces upstream,
    /// and it still forces quoting: the source text spanned lines, and a reader that splits on the
    /// delimiter has no way to know the space it now sees was one.
    private func escapeCSVField(_ field: String, options: CSVExportOptions, originalHadLineBreaks: Bool = false) -> String {
        let escaped = PluginRowWriters.csvField(field, options: writeOptions(options))
        guard originalHadLineBreaks, options.quoteHandling == .asNeeded, !escaped.hasPrefix("\"") else {
            return escaped
        }
        return "\"\(escaped.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func writeOptions(_ options: CSVExportOptions) -> PluginCsvWriteOptions {
        PluginCsvWriteOptions(
            delimiter: options.delimiter.actualValue,
            quoteHandling: quoteHandling(options.quoteHandling),
            lineEnding: options.lineBreak.value,
            nullAsEmpty: true,
            sanitizesFormulas: options.sanitizeFormulas,
            flattensLineBreaks: false
        )
    }

    private func quoteHandling(_ handling: CSVQuoteHandling) -> PluginCsvWriteOptions.QuoteHandling {
        switch handling {
        case .always: return .always
        case .never: return .never
        case .asNeeded: return .asNeeded
        }
    }
}
