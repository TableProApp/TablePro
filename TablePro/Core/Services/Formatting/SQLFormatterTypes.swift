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

/// The case the formatter writes a keyword in.
///
/// `preserve` keeps the spelling that is already in the statement wherever one exists; a keyword
/// the formatter synthesizes, such as the `BY` of a split `ORDER BY`, has no such spelling and is
/// written lower case.
enum SQLFormatterKeywordCase {
    case upper
    case lower
    case preserve

    /// `upper` is the token's uppercased form, `original` the spelling the statement already had.
    func applied(upper: String, original: String) -> String {
        switch self {
        case .upper: return upper
        case .lower: return upper.lowercased()
        case .preserve: return original
        }
    }

    /// A keyword the formatter writes from nothing, so there is no original spelling to preserve.
    func synthesized(_ upper: String) -> String {
        switch self {
        case .upper: return upper
        case .lower, .preserve: return upper.lowercased()
        }
    }

    /// Whether a token that is really a function or type name keeps the spelling it was written
    /// with. Only `preserve` has nothing to decide, because it keeps every spelling anyway.
    var rewritesKeywords: Bool { self != .preserve }
}

/// Configuration for SQL formatting behavior
struct SQLFormatterOptions {
    var keywordCase: SQLFormatterKeywordCase = .upper
    var indentSize: Int = 2
    var preserveComments: Bool = true

    static let `default` = SQLFormatterOptions()
}

// MARK: - Formatter Result

/// Result of a formatting operation with cursor mapping
struct SQLFormatterResult {
    let formattedSQL: String
    let cursorOffset: Int?

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
            return String(format: String(localized: "Formatting not supported for %@"), type.rawValue)
        case .invalidCursorPosition(let pos, let max):
            return String(format: String(localized: "Cursor position %d exceeds SQL length (%d)"), pos, max)
        case .internalError(let message):
            return String(format: String(localized: "Formatter error: %@"), message)
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
