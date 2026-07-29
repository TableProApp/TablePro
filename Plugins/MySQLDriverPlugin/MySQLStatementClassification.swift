//
//  MySQLStatementClassification.swift
//  MySQLDriverPlugin
//

internal func mysqlStatementIsReadOnly(_ query: String) -> Bool {
    let keyword = query
        .drop(while: { $0.isWhitespace })
        .prefix(while: { $0.isLetter })
        .uppercased()
    switch keyword {
    case "SELECT", "SHOW", "DESCRIBE", "DESC":
        return true
    default:
        return false
    }
}
