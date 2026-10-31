//
//  SQLEscaping.swift
//  TablePro
//
//  Shared utilities for SQL string escaping to prevent SQL injection.
//  Used across ExportService, SQLStatementGenerator, and other SQL-generating code.
//

import Foundation

/// Centralized SQL escaping utilities to prevent SQL injection vulnerabilities
enum SQLEscaping {
    /// Escape a string value for use in SQL string literals using ANSI SQL rules.
    /// Only doubles single quotes and strips null bytes.
    ///
    /// For database-specific escaping (e.g., MySQL backslash sequences), use the
    /// driver's `escapeStringLiteral` method instead.
    ///
    /// - Parameter str: The raw string to escape
    /// - Returns: The escaped string safe for use in ANSI SQL string literals
    static func escapeStringLiteral(_ str: String) -> String {
        var result = str
        result = result.replacingOccurrences(of: "'", with: "''", options: .literal)
        result = result.replacingOccurrences(of: "\0", with: "", options: .literal)
        return result
    }

    /// Quote a SQL identifier using ANSI double-quote rules, doubling any embedded quote.
    static func quoteIdentifier(_ identifier: String) -> String {
        let quote = "\""
        let escaped = identifier.replacingOccurrences(of: quote, with: quote + quote, options: .literal)
        return "\(quote)\(escaped)\(quote)"
    }

    /// Escape wildcards in LIKE patterns while preserving intentional wildcards
    ///
    /// This is useful when building LIKE clauses where the search term should be treated literally.
    ///
    /// - Parameter value: The value to escape
    /// - Returns: The escaped value with %, _, and \ escaped
    static func escapeLikeWildcards(_ value: String) -> String {
        var result = value
        result = result.replacingOccurrences(of: "\\", with: "\\\\", options: .literal)
        result = result.replacingOccurrences(of: "%", with: "\\%", options: .literal)
        result = result.replacingOccurrences(of: "_", with: "\\_", options: .literal)
        return result
    }
}
