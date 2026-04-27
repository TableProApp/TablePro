//
//  DialectQuoteHelper.swift
//  TablePro
//
//  Builds an identifier-quoting closure from a SQL dialect descriptor.
//

import Foundation
import TableProPluginKit

/// Build an identifier-quoting closure from a dialect descriptor.
/// NoSQL databases (nil dialect) use identity (return name as-is).
func quoteIdentifierFromDialect(_ dialect: SQLDialectDescriptor?) -> (String) -> String {
    guard let dialect else { return { $0 } }
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

/// Resolve a SQL dialect for a given database type, falling back to the
/// plugin metadata registry when no explicit dialect is supplied.
/// Returns nil for NoSQL databases (no SQL dialect registered).
func resolveSQLDialect(
    for databaseType: DatabaseType,
    explicit: SQLDialectDescriptor? = nil
) -> SQLDialectDescriptor? {
    if let explicit { return explicit }
    return PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?.editor.sqlDialect
}
