//
//  MySQLStatementKeyword.swift
//  MySQLDriverPlugin
//

import Foundation

/// Whether the statement answers with text the server builds itself, which MySQL before 5.0 labels
/// binary although it is in `character_set_results`: measured for `SHOW`, `DESCRIBE` and `HELP` on
/// 4.1.22, and the table maintenance statements build the same columns. `EXPLAIN <table>` is
/// `DESCRIBE`; `EXPLAIN SELECT` labels its text utf8 there, so passing it through changes nothing.
nonisolated internal func mysqlStatementListsServerMetadata(_ query: String) -> Bool {
    switch mysqlLeadingKeyword(query) {
    case "SHOW", "DESCRIBE", "DESC", "EXPLAIN", "HELP", "CHECK", "ANALYZE", "OPTIMIZE", "REPAIR", "CHECKSUM":
        return true
    default:
        return false
    }
}

/// The first keyword, past whitespace and the comments a user or a tool puts before a statement.
/// A `/*! ... */` executable comment is the statement's own text, so it ends the scan.
nonisolated internal func mysqlLeadingKeyword(_ query: String) -> String {
    var rest = Substring(query)
    while true {
        rest = rest.drop(while: { $0.isWhitespace })
        if rest.hasPrefix("/*"), !rest.hasPrefix("/*!") {
            guard let end = rest.range(of: "*/") else { return "" }
            rest = rest[end.upperBound...]
        } else if rest.hasPrefix("#") || (rest.hasPrefix("--") && rest.dropFirst(2).first?.isWhitespace != false) {
            guard let end = rest.firstIndex(where: { $0.isNewline }) else { return "" }
            rest = rest[end...]
        } else {
            break
        }
    }
    return rest.prefix(while: { $0.isLetter }).uppercased()
}
