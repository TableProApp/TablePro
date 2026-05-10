//
//  ParsedRow.swift
//  TablePro
//
//  Represents a parsed row of data from clipboard before insertion.
//

import Foundation
import TableProPluginKit

/// Represents a single parsed row ready for insertion
struct ParsedRow {
    /// Column values (nil represents NULL)
    let values: [PluginCellValue]

    /// Original line number in clipboard (for error reporting)
    let sourceLineNumber: Int

    /// Check if row has valid data
    var isValid: Bool {
        !values.isEmpty
    }

    /// Check if all values are NULL
    var isAllNull: Bool {
        values.allSatisfy { $0 == nil }
    }
}

/// Error types for row parsing
enum RowParseError: LocalizedError {
    case emptyClipboard
    case noValidRows
    case columnCountMismatch(expected: Int, actual: Int, line: Int)
    case invalidFormat(reason: String)

    var errorDescription: String? {
        switch self {
        case .emptyClipboard:
            return String(localized: "Clipboard is empty or contains no text data.")
        case .noValidRows:
            return String(localized: "No valid rows found in clipboard data.")
        case .columnCountMismatch(let expected, let actual, let line):
            return String(format: String(localized: "Column count mismatch on line %d: expected %d columns, found %d."), line, expected, actual)
        case .invalidFormat(let reason):
            return String(format: String(localized: "Invalid data format: %@"), reason)
        }
    }
}
