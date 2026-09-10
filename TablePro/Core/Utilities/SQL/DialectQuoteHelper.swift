//
//  DialectQuoteHelper.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum SQLDialectError: Error, LocalizedError {
    case dialectUnavailable(typeId: String)

    var errorDescription: String? {
        switch self {
        case .dialectUnavailable(let typeId):
            return String(
                format: String(localized: "SQL dialect for %@ is not available. The plugin may not be installed or loaded."),
                typeId
            )
        }
    }
}

func quoteIdentifierFromDialect(_ dialect: SQLDialectDescriptor) -> @Sendable (String) -> String {
    let q = dialect.identifierQuote
    if q == "[" {
        return { name in
            let escaped = name.replacingOccurrences(of: "]", with: "]]")
            return "[\(escaped)]"
        }
    }
    return { name in
        let escaped = name.replacingOccurrences(of: q, with: q + q)
        return "\(q)\(escaped)\(q)"
    }
}

/// The body of a single-quoted literal, escaped the way the engine reads it back.
///
/// MySQL, MariaDB, ClickHouse and Snowflake treat a backslash as an escape inside a literal, so a
/// value holding one has to double it. Writing ANSI rules for those engines does not fail: it
/// silently rewrites the data, and `C:\temp\next` comes back with a tab and a newline in it.
///
/// The escaped set matches what the MySQL driver itself writes, character for character, so a dump
/// taken with a driver and one taken without are the same file. `\u{1A}` is the one that matters
/// beyond tidiness: a raw SUB byte truncates a dump fed to the Windows `mysql` client, which is why
/// `mysqldump` writes `\Z`.
///
/// Dameng is the one engine a static descriptor cannot answer for, because it detects its own
/// escaping at connect time and its descriptor carries the pre-detection default. Ask its driver,
/// which is what every path holding one already does.
func escapeStringLiteralFromDialect(_ dialect: SQLDialectDescriptor) -> @Sendable (String) -> String {
    guard dialect.requiresBackslashEscaping else { return SQLEscaping.escapeStringLiteral }
    return { value in
        var result = value
        result = result.replacingOccurrences(of: "\\", with: "\\\\")
        result = result.replacingOccurrences(of: "'", with: "''")
        result = result.replacingOccurrences(of: "\n", with: "\\n")
        result = result.replacingOccurrences(of: "\r", with: "\\r")
        result = result.replacingOccurrences(of: "\t", with: "\\t")
        result = result.replacingOccurrences(of: "\0", with: "\\0")
        result = result.replacingOccurrences(of: "\u{08}", with: "\\b")
        result = result.replacingOccurrences(of: "\u{0C}", with: "\\f")
        result = result.replacingOccurrences(of: "\u{1A}", with: "\\Z")
        return result
    }
}

func resolveSQLDialect(
    for databaseType: DatabaseType,
    explicit: SQLDialectDescriptor? = nil
) throws -> SQLDialectDescriptor {
    if let explicit { return explicit }
    if let dialect = PluginMetadataRegistry.shared
        .snapshot(for: databaseType)?.editor.sqlDialect {
        return dialect
    }
    throw SQLDialectError.dialectUnavailable(typeId: databaseType.pluginTypeId)
}
