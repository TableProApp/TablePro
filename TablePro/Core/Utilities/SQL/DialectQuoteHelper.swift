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
