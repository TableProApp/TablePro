//
//  ImportErrorReport.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// The rows an import skipped, written to a file the user can open.
///
/// Skip and continue reports a count, and a count is not actionable: a user told that 412 of 50,000
/// rows were skipped has no way to find out which ones without running the import again against a
/// database that now holds the other 49,588. The report names the line and the server's own error
/// for each one.
enum ImportErrorReport {
    /// How many rows the report lists. A file per skipped row is unbounded, and past a few thousand
    /// the file stops being something a person reads; the header says how many were left out.
    static let maximumListedRows = 1_000

    static func makeCSV(
        sourceFileName: String,
        targetTable: String?,
        errors: [PluginImportResult.ImportStatementError],
        totalSkipped: Int
    ) -> String {
        var lines: [String] = []
        lines.append("# TablePro import errors")
        lines.append("# Source: \(csvField(sourceFileName))")
        if let targetTable, !targetTable.isEmpty {
            lines.append("# Target: \(csvField(targetTable))")
        }
        lines.append("# Skipped rows: \(totalSkipped)")
        if totalSkipped > errors.count {
            lines.append("# Listed below: \(errors.count)")
        }
        lines.append("line,statement,error")
        for error in errors.prefix(maximumListedRows) {
            lines.append([
                String(error.line),
                csvField(error.statement),
                csvField(error.errorMessage)
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A default name beside the source file, so the report is where the user is already looking.
    static func defaultFileName(forSource sourceFileName: String) -> String {
        let stem = (sourceFileName as NSString).deletingPathExtension
        let safeStem = stem.isEmpty ? "import" : stem
        return "\(safeStem)-errors.csv"
    }

    /// Quotes only what has to be quoted, and doubles an interior quote, which is what every
    /// spreadsheet reads back as one quote rather than the start of a new field.
    ///
    /// A value opening with `=`, `+`, `-` or `@` is prefixed with a quote first. The text here is
    /// the server's own error message, which quotes values the server was handed, so a row rejected
    /// for holding `=cmd|'/c calc'!A1` would otherwise put that straight into a cell the user opens
    /// in Excel. The CSV export guards the same way, for the same reason.
    private static func csvField(_ value: String) -> String {
        var flattened = value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        if let first = flattened.first, Self.formulaPrefixes.contains(first) {
            flattened = "'" + flattened
        }
        guard flattened.contains(",") || flattened.contains("\"") else { return flattened }
        return "\"\(flattened.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static let formulaPrefixes: Set<Character> = ["=", "+", "-", "@"]
}
