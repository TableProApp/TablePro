//
//  RowParser.swift
//  TablePro
//
//  Parses clipboard text data into rows for insertion.
//  Supports TSV (tab-separated values) format with extensibility for CSV/JSON.
//

import Foundation
import TableProPluginKit

/// Protocol for parsing row data from text
protocol RowDataParser {
    /// Parse text into array of parsed rows
    /// - Parameters:
    ///   - text: Raw text from clipboard
    ///   - schema: Table schema for validation
    /// - Returns: Result containing parsed rows or error
    func parse(_ text: String, schema: TableSchema) -> Result<[ParsedRow], RowParseError>
}

// One line's fields fitted to the table: a short line's missing fields are blank cells, extra fields are dropped,
// and the key is left to the server.
private func fittedRow(
    _ fields: [String],
    lineNumber: Int,
    schema: TableSchema,
    normalize: (String) -> String?
) -> ParsedRow {
    var values: [String?] = []
    var blankColumns: Set<Int> = []
    for (column, field) in fields.prefix(schema.columnCount).enumerated() {
        if field.trimmingCharacters(in: .whitespaces).isEmpty { blankColumns.insert(column) }
        values.append(normalize(field))
    }
    while values.count < schema.columnCount {
        blankColumns.insert(values.count)
        values.append(nil)
    }
    var cells = values.map(PluginCellValue.fromOptional)
    var defaultColumns: Set<Int> = []
    if let pkIndex = schema.primaryKeyIndex, pkIndex < cells.count {
        cells[pkIndex] = .columnDefault
        defaultColumns.insert(pkIndex)
        blankColumns.remove(pkIndex)
    }
    return ParsedRow(
        values: cells,
        sourceLineNumber: lineNumber,
        expressionColumns: defaultColumns,
        blankColumns: blankColumns
    )
}

/// TSV (Tab-Separated Values) parser
/// Matches the format produced by RowOperationsManager.copySelectedRowsToClipboard()
struct TSVRowParser: RowDataParser {
    func parse(_ text: String, schema: TableSchema) -> Result<[ParsedRow], RowParseError> {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.emptyClipboard)
        }

        // Only tested for blankness: trimming the line itself drops a leading empty field and shifts the row left.
        let lines = text.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        guard !lines.isEmpty else {
            return .failure(.noValidRows)
        }

        var parsedRows: [ParsedRow] = []

        for (index, line) in lines.enumerated() {
            parsedRows.append(fittedRow(
                line.components(separatedBy: "\t"),
                lineNumber: index + 1,
                schema: schema,
                normalize: normalizeValue
            ))
        }

        guard !parsedRows.isEmpty else {
            return .failure(.noValidRows)
        }

        return .success(parsedRows)
    }

    // A cell's own leading and trailing spaces are data; only a blank or NULL cell reads as no value.
    private func normalizeValue(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty || trimmed.uppercased() == "NULL" {
            return nil
        }

        return rawValue
    }
}

// MARK: - CSV Parser

/// RFC 4180-compliant CSV parser
/// Handles quoted fields, escaped double-quotes, and line breaks within quoted values.
struct CSVRowParser: RowDataParser {
    /// Delimiter scalar (comma by default, but extensible)
    private let delimiter: Unicode.Scalar

    init(delimiter: Unicode.Scalar = ",") {
        self.delimiter = delimiter
    }

    func parse(_ text: String, schema: TableSchema) -> Result<[ParsedRow], RowParseError> {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.emptyClipboard)
        }

        let records = parseCSVRecords(text)
        guard !records.isEmpty else {
            return .failure(.noValidRows)
        }

        let startIndex = isHeaderRow(records[0], schema: schema) ? 1 : 0
        guard startIndex < records.count else {
            return .failure(.noValidRows)
        }

        var parsedRows: [ParsedRow] = []

        for recordIndex in startIndex..<records.count {
            parsedRows.append(fittedRow(
                records[recordIndex],
                lineNumber: recordIndex + 1,
                schema: schema,
                normalize: normalizeValue
            ))
        }

        guard !parsedRows.isEmpty else {
            return .failure(.noValidRows)
        }

        return .success(parsedRows)
    }

    // MARK: - RFC 4180 CSV Parsing

    /// Parse CSV text into array of records (each record is an array of field strings)
    private func parseCSVRecords(_ text: String) -> [[String]] {
        var records: [[String]] = []
        var currentField = ""
        var currentRecord: [String] = []
        var inQuotes = false
        let chars = Array(text.unicodeScalars)
        var i = 0

        while i < chars.count {
            let c = chars[i]

            if inQuotes {
                if c == "\"" {
                    // Check for escaped quote ("")
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        currentField.append("\"")
                        i += 2
                        continue
                    }
                    // End of quoted field
                    inQuotes = false
                    i += 1
                    continue
                }
                // Any character inside quotes (including newlines, delimiters)
                currentField.unicodeScalars.append(c)
                i += 1
            } else {
                if c == "\"" && currentField.isEmpty {
                    // Start of quoted field
                    inQuotes = true
                    i += 1
                } else if c == delimiter {
                    // Field separator
                    currentRecord.append(currentField)
                    currentField = ""
                    i += 1
                } else if c == "\r" {
                    // CR or CRLF line ending
                    currentRecord.append(currentField)
                    currentField = ""
                    if !currentRecord.allSatisfy({ $0.isEmpty }) || !currentRecord.isEmpty {
                        records.append(currentRecord)
                    }
                    currentRecord = []
                    // Skip \n after \r
                    if i + 1 < chars.count && chars[i + 1] == "\n" {
                        i += 1
                    }
                    i += 1
                } else if c == "\n" {
                    // LF line ending
                    currentRecord.append(currentField)
                    currentField = ""
                    if !currentRecord.allSatisfy({ $0.isEmpty }) || !currentRecord.isEmpty {
                        records.append(currentRecord)
                    }
                    currentRecord = []
                    i += 1
                } else {
                    currentField.unicodeScalars.append(c)
                    i += 1
                }
            }
        }

        // Handle last field/record
        if !currentField.isEmpty || !currentRecord.isEmpty {
            currentRecord.append(currentField)
            records.append(currentRecord)
        }

        // Filter out empty records (all-empty-string records)
        return records.filter { record in
            record.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
    }

    // MARK: - Helpers

    /// Detect if a row is a header row by matching column names
    private func isHeaderRow(_ fields: [String], schema: TableSchema) -> Bool {
        guard fields.count == schema.columnCount else { return false }
        let matchCount = fields.enumerated().filter { index, field in
            field.trimmingCharacters(in: .whitespaces).lowercased()
                == schema.columns[index].lowercased()
        }.count
        // If most fields match column names, treat as header
        return matchCount > schema.columnCount / 2
    }

    private func normalizeValue(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.uppercased() == "NULL" {
            return nil
        }
        return trimmed
    }
}
