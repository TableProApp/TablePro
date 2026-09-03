//
//  PluginRowWriters.swift
//  TableProPluginKit
//

import Foundation

/// How a value becomes a CSV field.
public struct PluginCsvWriteOptions: Sendable, Equatable {
    public enum QuoteHandling: String, Sendable, Codable, CaseIterable {
        case always
        case asNeeded
        case never
    }

    public let delimiter: String
    public let quoteHandling: QuoteHandling
    public let lineEnding: String
    public let nullAsEmpty: Bool

    /// Prefixes a value opening with `=`, `+`, `-` or `@` with a quote. A spreadsheet treats a cell
    /// starting with one of those as a formula, and the values in an export come from the database
    /// rather than from the person opening the file.
    public let sanitizesFormulas: Bool

    /// Replaces a line break inside a value with a space. Off means the value keeps its break and is
    /// quoted instead, which every conforming reader handles and some spreadsheets do not.
    public let flattensLineBreaks: Bool

    public init(
        delimiter: String = ",",
        quoteHandling: QuoteHandling = .asNeeded,
        lineEnding: String = "\n",
        nullAsEmpty: Bool = true,
        sanitizesFormulas: Bool = true,
        flattensLineBreaks: Bool = false
    ) {
        self.delimiter = delimiter
        self.quoteHandling = quoteHandling
        self.lineEnding = lineEnding
        self.nullAsEmpty = nullAsEmpty
        self.sanitizesFormulas = sanitizesFormulas
        self.flattensLineBreaks = flattensLineBreaks
    }

    public static let `default` = PluginCsvWriteOptions()

    /// What a tool result wants: CRLF, quoted only where needed, formulas neutralised.
    public static let toolResult = PluginCsvWriteOptions(lineEnding: "\r\n")
}

/// The one implementation of value-to-text for every export path.
///
/// The escaping rules are the part that has to agree everywhere and the part that is easy to get
/// subtly wrong: a doubled quote, a formula prefix, a line break inside a field, an unquoted
/// delimiter. Having the export plugins and the MCP tool each carry their own copy meant a fix to
/// one never reached the other.
public enum PluginRowWriters {
    public static let formulaPrefixes: Set<Character> = ["=", "+", "-", "@"]

    // MARK: - CSV

    public static func csvLine(_ fields: [String], options: PluginCsvWriteOptions) -> String {
        fields.map { csvField($0, options: options) }.joined(separator: options.delimiter)
    }

    public static func csvField(_ value: String, options: PluginCsvWriteOptions) -> String {
        var processed = value
        if options.flattensLineBreaks {
            processed = processed
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
        }
        var wasNeutralised = false
        if options.sanitizesFormulas, let first = processed.first, isFormulaLead(first) {
            processed = "'" + processed
            wasNeutralised = true
        }

        switch options.quoteHandling {
        case .always:
            return quoted(processed)
        case .never:
            return processed
        case .asNeeded:
            let needsQuotes = processed.contains(options.delimiter)
                || processed.contains("\"")
                || processed.contains("\n")
                || processed.contains("\r")
                || processed.contains("\t")
                || wasNeutralised
            return needsQuotes ? quoted(processed) : processed
        }
    }

    /// A leading tab or carriage return is treated as a formula lead too: Excel strips it before
    /// parsing the cell, so `\t=1+1` reaches the formula engine exactly as `=1+1` would.
    private static func isFormulaLead(_ character: Character) -> Bool {
        formulaPrefixes.contains(character) || character == "\t" || character == "\r"
    }

    private static func quoted(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    // MARK: - JSON

    /// A JSON value for one cell, already serialized. `preserveAsString` writes every value as a
    /// string, which is what keeps a leading zero on a postcode or an identifier.
    public static func jsonValue(
        _ value: PluginCellValue,
        columnTypeName: String = "",
        preserveAsString: Bool = false
    ) -> String {
        switch value {
        case .null:
            return "null"
        case .bytes(let data):
            return "\"\(data.base64EncodedString())\""
        case .text(let text):
            guard !preserveAsString, isJSONNumeric(text, columnTypeName: columnTypeName) else {
                return "\"\(PluginExportUtilities.escapeJSONString(text))\""
            }
            return text
        }
    }

    /// A text cell is written unquoted only when its column is numeric and the text really is a
    /// number. Guessing from the text alone turns a numeric-looking identifier into a number and
    /// loses its leading zeros.
    private static func isJSONNumeric(_ text: String, columnTypeName: String) -> Bool {
        guard !columnTypeName.isEmpty else { return false }
        guard PluginExportUtilities.isNumericColumnType(columnTypeName) else { return false }
        return PluginNumericLiteral.isValid(text)
    }

    public static func jsonObject(
        columns: [String],
        values: [String],
        includesNulls: Bool = true
    ) -> String {
        var fields: [String] = []
        for (index, column) in columns.enumerated() where index < values.count {
            let value = values[index]
            guard includesNulls || value != "null" else { continue }
            fields.append("\"\(PluginExportUtilities.escapeJSONString(column))\": \(value)")
        }
        return "{\(fields.joined(separator: ", "))}"
    }

    // MARK: - SQL

    /// One `INSERT` for one row. Batched inserts are the SQL export plugin's own concern; this is
    /// the single-row shape a tool result and a one-off statement both want.
    public static func sqlInsert(
        table: String,
        columns: [String],
        values: [String]
    ) -> String? {
        guard !columns.isEmpty else { return nil }
        return "INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(values.joined(separator: ", ")));"
    }
}
