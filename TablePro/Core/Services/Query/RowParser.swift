//
//  RowParser.swift
//  TablePro
//
//  Parses clipboard text data into rows for insertion.
//  Supports TSV (tab-separated values) format with extensibility for CSV/JSON.
//

import Foundation

/// Protocol for parsing row data from text
protocol RowDataParser {
    /// Parse text into array of parsed rows
    /// - Parameters:
    ///   - text: Raw text from clipboard
    ///   - schema: Table schema for validation
    /// - Returns: Result containing parsed rows or error
    func parse(_ text: String, schema: TableSchema) -> Result<[ParsedRow], RowParseError>
}

/// TSV (Tab-Separated Values) parser
/// Matches the format produced by RowOperationsManager.copySelectedRowsToClipboard()
struct TSVRowParser: RowDataParser {
    func parse(_ text: String, schema: TableSchema) -> Result<[ParsedRow], RowParseError> {
        // Check for empty input
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.emptyClipboard)
        }

        // Split into lines
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else {
            return .failure(.noValidRows)
        }

        var parsedRows: [ParsedRow] = []

        for (index, line) in lines.enumerated() {
            let lineNumber = index + 1

            // Parse TSV line
            let rawValues = line.components(separatedBy: "\t")
            var values = rawValues.map { normalizeValue($0) }

            // Handle column count mismatch
            if values.count < schema.columnCount {
                // Pad with NULL for missing columns
                while values.count < schema.columnCount {
                    values.append(nil)
                }
            } else if values.count > schema.columnCount {
                // Truncate extra columns
                values = Array(values.prefix(schema.columnCount))
            }

            // Set primary key to __DEFAULT__ (let DB auto-generate)
            if let pkIndex = schema.primaryKeyIndex, pkIndex < values.count {
                values[pkIndex] = "__DEFAULT__"
            }

            let parsedRow = ParsedRow(values: values, sourceLineNumber: lineNumber)
            parsedRows.append(parsedRow)
        }

        guard !parsedRows.isEmpty else {
            return .failure(.noValidRows)
        }

        return .success(parsedRows)
    }

    // MARK: - Private Helpers

    /// Normalize a single value from clipboard
    /// - Parameter rawValue: Raw string value
    /// - Returns: Normalized value (nil for NULL, trimmed string otherwise)
    private func normalizeValue(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespaces)

        // Empty string or "NULL" (case-insensitive) → nil
        if trimmed.isEmpty || trimmed.uppercased() == "NULL" {
            return nil
        }

        return trimmed
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

        // Detect header row: if first row's values match column names, skip it
        let startIndex = isHeaderRow(records[0], schema: schema) ? 1 : 0
        guard startIndex < records.count else {
            return .failure(.noValidRows)
        }

        var parsedRows: [ParsedRow] = []

        for recordIndex in startIndex..<records.count {
            let lineNumber = recordIndex + 1
            var values = records[recordIndex].map { normalizeValue($0) }

            // Handle column count mismatch
            if values.count < schema.columnCount {
                while values.count < schema.columnCount {
                    values.append(nil)
                }
            } else if values.count > schema.columnCount {
                values = Array(values.prefix(schema.columnCount))
            }

            // Set primary key to __DEFAULT__ (let DB auto-generate)
            if let pkIndex = schema.primaryKeyIndex, pkIndex < values.count {
                values[pkIndex] = "__DEFAULT__"
            }

            parsedRows.append(ParsedRow(values: values, sourceLineNumber: lineNumber))
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
