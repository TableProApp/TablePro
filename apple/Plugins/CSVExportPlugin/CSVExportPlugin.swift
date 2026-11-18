//
//  CSVExportPlugin.swift
//  CSVExportPlugin
//

import Combine
import Foundation
import TableProPluginKit

nonisolated final class CSVExportPlugin: ObservableObject, ExportFormatPlugin, SettablePlugin, @unchecked Sendable {
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

    // A nonisolated class cannot hold an @Published property, so the change is announced by hand.
    var settings = CSVExportOptions() {
        willSet { objectWillChange.send() }
        didSet { saveSettings() }
    }

    required init() { loadSettings() }

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
        let format = CSVRowFormat(options: options)
        let lineBreak = format.lineBreak
        let encoding = options.encoding
        var output = PluginExportOutputBuffer(fileHandle: fileHandle)
        var line = ""
        var report = CSVEncodingReport()
        var neutralisedCount = 0

        if options.writesByteOrderMark, !encoding.byteOrderMark.isEmpty {
            try output.append(encoding.byteOrderMark)
        }

        for (index, table) in tables.enumerated() {
            try progress.checkCancellation()

            progress.setCurrentTable(table.qualifiedName, index: index + 1)

            if tables.count > 1 {
                let sanitizedName = PluginExportUtilities.sanitizeForSQLComment(table.qualifiedName)
                try write(
                    "# Table: \(sanitizedName)\(lineBreak)",
                    to: &output,
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
                            .map { escapeCSVField($0, format: format, sanitizes: options.sanitizeFormulas) }
                            .joined(separator: format.delimiter)
                        try write(headerLine + lineBreak, to: &output, encoding: encoding, report: &report)
                    }
                    isFirstBatch = false
                case .rows(let rows):
                    for row in rows {
                        buildCSVRow(
                            row,
                            columnNumbers: columnNumbers,
                            format: format,
                            into: &line,
                            neutralisedCount: &neutralisedCount
                        )
                        try write(line, to: &output, encoding: encoding, report: &report)
                        progress.incrementRow()
                    }
                }
            }

            if index < tables.count - 1 {
                try write("\(lineBreak)\(lineBreak)", to: &output, encoding: encoding, report: &report)
            }
        }

        try progress.checkCancellation()
        try output.flush()
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

    // A line is encoded whole, since Foundation composes across the characters it is given.
    private func write(
        _ text: String,
        to output: inout PluginExportOutputBuffer,
        encoding: PluginTextEncoding,
        report: inout CSVEncodingReport
    ) throws {
        guard encoding != .utf8 else {
            try output.append(text)
            return
        }
        let encoded = try PluginTextEncoder.encode(
            text,
            as: encoding,
            detectingUnrepresented: !report.isSaturated
        )
        report.record(encoded.unrepresented)
        try output.append(encoded.data)
    }

    private func buildCSVRow(
        _ row: [PluginCellValue],
        columnNumbers: [PluginColumnNumbers],
        format: CSVRowFormat,
        into line: inout String,
        neutralisedCount: inout Int
    ) {
        line.removeAll(keepingCapacity: true)

        for (index, cell) in row.enumerated() {
            if index > 0 {
                line += format.delimiter
            }
            switch cell {
            case .null:
                line += format.options.convertNullToEmpty ? "" : "NULL"
            case .text(let text):
                appendCSVField(
                    text, column: index, columnNumbers: columnNumbers, format: format,
                    to: &line, neutralisedCount: &neutralisedCount
                )
            case .bytes(let data):
                appendCSVField(
                    "0x" + PluginHexText.uppercase(data), column: index, columnNumbers: columnNumbers, format: format,
                    to: &line, neutralisedCount: &neutralisedCount
                )
            }
        }

        line += format.lineBreak
    }

    // A text column holding "1.10" is a version or a code; a column with no usable type keeps the decimal comma.
    private func appendCSVField(
        _ value: String,
        column: Int,
        columnNumbers: [PluginColumnNumbers],
        format: CSVRowFormat,
        to line: inout String,
        neutralisedCount: inout Int
    ) {
        let options = format.options
        let takesDecimalComma = column >= columnNumbers.count || columnNumbers[column] != .text

        if format.writesVerbatim(value, takesDecimalComma: takesDecimalComma) {
            if options.quoteHandling == .always {
                line += "\""
                line += value
                line += "\""
            } else {
                line += value
            }
            return
        }

        var processed = value
        // `\r\n` is one Character, so only a scalar test sees a Windows line break.
        let hadLineBreaks = value.unicodeScalars.contains { $0 == "\n" || $0 == "\r" }

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
        line += escapeCSVField(processed, format: format, sanitizes: sanitizes, originalHadLineBreaks: hadLineBreaks)
    }

    // `originalHadLineBreaks` still forces quoting after the breaks became spaces: the source text spanned lines.
    private func escapeCSVField(
        _ field: String,
        format: CSVRowFormat,
        sanitizes: Bool,
        originalHadLineBreaks: Bool = false
    ) -> String {
        let escaped = PluginRowWriters.csvField(field, options: format.writeOptions(sanitizes: sanitizes))
        guard originalHadLineBreaks, format.options.quoteHandling == .asNeeded, escaped.unicodeScalars.first != "\"" else {
            return escaped
        }
        return "\"\(escaped.replacingOccurrences(of: "\"", with: "\"\"", options: .literal))\""
    }
}
