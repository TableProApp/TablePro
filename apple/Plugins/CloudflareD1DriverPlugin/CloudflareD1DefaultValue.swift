//
//  CloudflareD1DefaultValue.swift
//  CloudflareD1DriverPlugin
//

import Foundation
import TableProSQLQuoting

// The pragma drops a default's parentheses and a bare word's quotes (3.54.0); only an expression has a call or an operator.
internal func cloudflareD1DefaultValueFromCatalog(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    let upper = value.uppercased()
    if upper == "NULL" || upper == "TRUE" || upper == "FALSE"
        || upper == "CURRENT_TIMESTAMP" || upper == "CURRENT_DATE" || upper == "CURRENT_TIME"
        || value.unicodeScalars.first == "(" || upper.unicodeScalars.starts(with: "X'".unicodeScalars)
        || Int64(value) != nil || Double(value) != nil
        || SQLQuoting.decodedStringLiteral(value) != nil {
        return value
    }
    return cloudflareD1LooksLikeExpression(value) ? "(\(value))" : SQLQuoting.stringLiteral(value)
}

private let cloudflareD1ExpressionScalars: Set<Unicode.Scalar> = ["(", ")", "|", "+", "-", "*", "/", "%", "<", ">", "=", "!", "~", "&", " ", ","]

internal func cloudflareD1LooksLikeExpression(_ value: String) -> Bool {
    value.unicodeScalars.contains { cloudflareD1ExpressionScalars.contains($0) }
}
