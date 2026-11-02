//
//  SQLEscaping.swift
//  TablePro
//

import Foundation
import TableProSQLQuoting

// ANSI rules for text no driver or session answers for. A driver's own escaper, or the session's escapes, wins.
enum SQLEscaping {
    static func escapeStringLiteral(_ str: String) -> String {
        SQLQuoting.stringLiteralBody(str)
    }

    static func quoteIdentifier(_ identifier: String) -> String {
        SQLQuoting.identifier(identifier)
    }

    static func escapeLikeWildcards(_ value: String) -> String {
        SQLQuoting.likePattern(value)
    }
}
