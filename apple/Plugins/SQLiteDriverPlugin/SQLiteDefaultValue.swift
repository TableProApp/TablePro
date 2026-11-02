//
//  SQLiteDefaultValue.swift
//  SQLiteDriverPlugin
//

import Foundation
import TableProSQLQuoting

// The pragma drops a default's parentheses and a bare word's quotes (3.54.0); only an expression has a call or an operator.
internal func sqliteDefaultValueFromCatalog(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    let upper = value.uppercased()
    if upper == "NULL" || upper == "TRUE" || upper == "FALSE"
        || upper == "CURRENT_TIMESTAMP" || upper == "CURRENT_DATE" || upper == "CURRENT_TIME"
        || value.unicodeScalars.first == "(" || upper.unicodeScalars.starts(with: "X'".unicodeScalars)
        || Int64(value) != nil || Double(value) != nil
        || SQLQuoting.decodedStringLiteral(value) != nil {
        return value
    }
    return sqliteLooksLikeExpression(value) ? "(\(value))" : SQLQuoting.stringLiteral(value)
}

private let sqliteExpressionScalars: Set<Unicode.Scalar> = ["(", ")", "|", "+", "-", "*", "/", "%", "<", ">", "=", "!", "~", "&", " ", ","]

internal func sqliteLooksLikeExpression(_ value: String) -> Bool {
    value.unicodeScalars.contains { sqliteExpressionScalars.contains($0) }
}
