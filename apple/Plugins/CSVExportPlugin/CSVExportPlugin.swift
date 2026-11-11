//
//  CSVExportPlugin.swift
//  CSVExportPlugin
//

import Combine
import Foundation
import SwiftUI
import TableProPluginKit

final class CSVExportPlugin: ObservableObject, ExportFormatPlugin, SettablePlugin, @unchecked Sendable {
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

    @Published var settings = CSVExportOptions() {
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
        var neutralisedCount = 0

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
            var columnNumbers: [PluginColumnNumbers] = []

            let stream = dataSource.streamRows(for: table)
            for try await element in stream {
                try progress.checkCancellation()

                switch element {
                case .header(let header):
                    columnNumbers = header.columnTypeNames.map { PluginColumnNumbers(typeName: $0) }
                    if isFirstBatch && options.includeFieldNames {
                        if options.sanitizeFormulas {
                            neutralisedCount += header.columns.filter(PluginRowWriters.isFormulaLike).count
                        }
                        let headerLine = header.columns
                            .map { escapeCSVField($0, options: options, sanitizes: options.sanitizeFormulas) }
                            .joined(separator: options.delimiter.actualValue)
                        try write(headerLine + lineBreak, to: fileHandle, encoding: encoding, report: &report)
                    }
                    isFirstBatch = false
                case .rows(let rows):
                    for row in rows {
                        try writeCSVRow(
                            row,
                            columnNumbers: columnNumbers,
                            options: options,
                            to: fileHandle,
                            report: &report,
                            neutralisedCount: &neutralisedCount
                        )
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
        return ExportFormatResult(warnings: report.warnings(for: encoding) + Self.neutralisedWarnings(neutralisedCount))
    }

    // The quote is part of the value for anything that imports the file, so the export says how many it changed.
    static func neutralisedWarnings(_ count: Int) -> [String] {
        guard count > 0 else { return [] }
        return [String(
            format: String(
                localized: """
                    Values a spreadsheet would read as formulas, written with a leading single quote: %lld. \
                    Turn off Sanitize formula-like values to export them unchanged.
                    """,
                bundle: .main
            ),
            Int64(count)
        )]
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

    // A text column holding "1.10" is a version or a code; a column with no usable type keeps the decimal comma.
    private func writeCSVRow(
        _ row: [PluginCellValue],
        columnNumbers: [PluginColumnNumbers],
        options: CSVExportOptions,
        to fileHandle: FileHandle,
        report: inout CSVEncodingReport,
        neutralisedCount: inout Int
    ) throws {
        var fields: [String] = []
        fields.reserveCapacity(row.count)

        for (index, cell) in row.enumerated() {
            let val: String
            switch cell {
            case .null:
                fields.append(options.convertNullToEmpty ? "" : "NULL")
                continue
            case .text(let s):
                val = s
            case .bytes(let d):
                val = "0x" + d.map { String(format: "%02X", $0) }.joined()
            }

            let takesDecimalComma = index >= columnNumbers.count || columnNumbers[index] != .text
            var processed = val
            // `\r\n` is one Character, so only a scalar test sees a Windows line break.
            let hadLineBreaks = val.unicodeScalars.contains { $0 == "\n" || $0 == "\r" }

            if options.convertLineBreakToSpace {
                processed = processed
                    .replacingOccurrences(of: "\r\n", with: " ", options: .literal)
                    .replacingOccurrences(of: "\r", with: " ", options: .literal)
                    .replacingOccurrences(of: "\n", with: " ", options: .literal)
            }

            var isCommaDecimal = false
            if options.decimalFormat == .comma, takesDecimalComma {
                let range = NSRange(processed.startIndex..., in: processed)
                if Self.decimalFormatRegex.firstMatch(in: processed, range: range) != nil {
                    processed = processed.replacingOccurrences(of: ".", with: ",")
                    isCommaDecimal = true
                }
            }

            // `-1,5` is still a number, and the quote would turn it into text.
            let sanitizes = options.sanitizeFormulas && !isCommaDecimal
            if sanitizes, PluginRowWriters.isFormulaLike(processed) {
                neutralisedCount += 1
            }
            fields.append(escapeCSVField(
                processed, options: options, sanitizes: sanitizes, originalHadLineBreaks: hadLineBreaks
            ))
        }

        try write(
            fields.joined(separator: options.delimiter.actualValue) + options.lineBreak.value,
            to: fileHandle,
            encoding: options.encoding,
            report: &report
        )
    }

    // `originalHadLineBreaks` still forces quoting after the breaks became spaces: the source text spanned lines.
    private func escapeCSVField(
        _ field: String,
        options: CSVExportOptions,
        sanitizes: Bool,
        originalHadLineBreaks: Bool = false
    ) -> String {
        let escaped = PluginRowWriters.csvField(field, options: writeOptions(options, sanitizes: sanitizes))
        guard originalHadLineBreaks, options.quoteHandling == .asNeeded, escaped.unicodeScalars.first != "\"" else {
            return escaped
        }
        return "\"\(escaped.replacingOccurrences(of: "\"", with: "\"\"", options: .literal))\""
    }

    private func writeOptions(_ options: CSVExportOptions, sanitizes: Bool) -> PluginCsvWriteOptions {
        PluginCsvWriteOptions(
            delimiter: options.delimiter.actualValue,
            quoteHandling: quoteHandling(options.quoteHandling),
            lineEnding: options.lineBreak.value,
            nullAsEmpty: true,
            sanitizesFormulas: sanitizes,
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
