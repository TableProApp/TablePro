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

        /// One plugin instance serves every window, and a dialog open in another window writes
        /// straight into `settings`. Reading it per row would let a picker change halfway through
        /// switch the delimiter, the line ending or the encoding of a file already being written.
        let options = settings
        let lineBreak = options.lineBreak.value
        let encoding = options.encoding
        var report = CSVEncodingReport()

        if options.writesByteOrderMark, !encoding.byteOrderMark.isEmpty {
            try fileHandle.write(contentsOf: Data(encoding.byteOrderMark))
        }

        for (index, table) in tables.enumerated() {
            try progress.checkCancellation()

            progress.setCurrentTable(table.qualifiedName, index: index + 1)

            if tables.count > 1 {
                let sanitizedName = PluginExportUtilities.sanitizeForSQLComment(table.qualifiedName)
                try write(
                    "# Table: \(sanitizedName)\(lineBreak)",
                    to: fileHandle,
                    encoding: encoding,
                    report: &report
                )
            }

            var isFirstBatch = true
            var columns: [String] = []

            let stream = dataSource.streamRows(table: table.name, databaseName: table.databaseName)
            for try await element in stream {
                try progress.checkCancellation()

                switch element {
                case .header(let header):
                    columns = header.columns
                    if isFirstBatch && options.includeFieldNames {
                        let headerLine = columns
                            .map { escapeCSVField($0, options: options) }
                            .joined(separator: options.delimiter.actualValue)
                        try write(headerLine + lineBreak, to: fileHandle, encoding: encoding, report: &report)
                    }
                    isFirstBatch = false
                case .rows(let rows):
                    for row in rows {
                        try writeCSVRow(row, options: options, to: fileHandle, report: &report)
                        progress.incrementRow()
                    }
                }
            }

            if index < tables.count - 1 {
                try write("\(lineBreak)\(lineBreak)", to: fileHandle, encoding: encoding, report: &report)
            }
        }

        try progress.checkCancellation()
        try fileHandle.close()
        try PluginExportUtilities.commitAtomicWrite(from: tempURL, to: destination)
        committed = true
        progress.finalizeTable()
        return ExportFormatResult(warnings: report.warnings(for: encoding))
    }

    // MARK: - Private

    /// Every byte this format writes goes through here, so the chosen encoding and the record of
    /// what it could not represent stay together. `String.toUTF8Data()` is left alone: seven
    /// plugins call it, and giving it an encoding parameter would replace its mangled symbol and
    /// stop every already-built plugin from loading.
    ///
    /// The encoding is passed in rather than read from `settings`, which one shared plugin
    /// instance publishes to every window: an export running while another window's dialog changes
    /// the picker would otherwise switch encoding mid-file, under a mark and a warning naming the
    /// one it started with.
    private func write(
        _ text: String,
        to fileHandle: FileHandle,
        encoding: PluginTextEncoding,
        report: inout CSVEncodingReport
    ) throws {
        let encoded = try PluginTextEncoder.encode(
            text,
            as: encoding,
            detectingUnrepresented: !report.isSaturated
        )
        report.record(encoded.unrepresented)
        try fileHandle.write(contentsOf: encoded.data)
    }

    private func writeCSVRow(
        _ row: [PluginCellValue],
        options: CSVExportOptions,
        to fileHandle: FileHandle,
        report: inout CSVEncodingReport
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

        try write(rowLine + lineBreak, to: fileHandle, encoding: options.encoding, report: &report)
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
