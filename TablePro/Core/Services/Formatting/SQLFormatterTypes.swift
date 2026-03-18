//
//  SQLFormatterTypes.swift
//  TablePro
//
//  Created by OpenCode on 1/17/26.
//

import Foundation

// Note: DatabaseType is defined in Models/DatabaseConnection.swift
// Swift doesn't require explicit imports within the same module

// MARK: - Formatter Options

/// Configuration for SQL formatting behavior
struct SQLFormatterOptions {
    var uppercaseKeywords: Bool = true
    var indentSize: Int = 2  // spaces per indent level
    var alignColumns: Bool = true
    var preserveComments: Bool = true
    var formatJoins: Bool = true
    var alignWhere: Bool = true

    /// Default options with all features enabled
    static let `default` = SQLFormatterOptions()
}

// MARK: - Formatter Result

/// Result of a formatting operation with cursor mapping
struct SQLFormatterResult {
    let formattedSQL: String
    let cursorOffset: Int?  // New cursor position (nil if no cursor provided)

    init(formattedSQL: String, cursorOffset: Int? = nil) {
        self.formattedSQL = formattedSQL
        self.cursorOffset = cursorOffset
    }
}

// MARK: - Formatter Error

/// Errors that can occur during SQL formatting
enum SQLFormatterError: LocalizedError {
    case emptyInput
    case dialectUnsupported(DatabaseType)
    case invalidCursorPosition(Int, max: Int)
    case internalError(String)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return String(localized: "Cannot format empty SQL")
        case .dialectUnsupported(let type):
            return String(localized: "Formatting not supported for \(type.rawValue)")
        case .invalidCursorPosition(let pos, let max):
            return String(localized: "Cursor position \(pos) exceeds SQL length (\(max))")
        case .internalError(let message):
            return String(localized: "Formatter error: \(message)")
        }
    }
}

// MARK: - Dialect Provider Protocol

/// Provides dialect-specific SQL formatting rules
protocol SQLDialectProvider {
    var keywords: Set<String> { get }
    var functions: Set<String> { get }
    var dataTypes: Set<String> { get }
    var identifierQuote: String { get }

    /// Check if a token is a keyword for this dialect
    func isKeyword(_ token: String) -> Bool

    /// Check if a token is a function for this dialect
    func isFunction(_ token: String) -> Bool

    /// Check if a token is a data type for this dialect
    func isDataType(_ token: String) -> Bool
}

// MARK: - Default Protocol Implementations

extension SQLDialectProvider {
    func isKeyword(_ token: String) -> Bool {
        keywords.contains(token.uppercased())
    }

    func isFunction(_ token: String) -> Bool {
        functions.contains(token.uppercased())
    }

    func isDataType(_ token: String) -> Bool {
        dataTypes.contains(token.uppercased())
    }
}
