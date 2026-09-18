//
//  LibSQLDefaultValue.swift
//  LibSQLDriverPlugin
//

import Foundation

/// A column default as `PRAGMA table_info` reports it, turned back into SQL that recreates it.
///
/// The pragma reports the fragment with any parentheses taken off, and a bare word with no quotes,
/// and those two are not the same thing. Measured on SQLite 3.54.0: `DEFAULT abc` is a text literal
/// and stores the string `abc`, while `DEFAULT (datetime('now'))` reads back as `datetime('now')`
/// and will not parse without its parentheses. Re-emitting either as the other fails, the bare word
/// with `default value of column [a] is not constant`.
///
/// An expression always carries a call or an operator; a bare word never does. That is what tells
/// them apart, and it is why a leading quote is not enough on its own: `'x' || 'y'` starts with one
/// and is still an expression.
internal func libSQLDefaultValueFromCatalog(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    let upper = value.uppercased()
    if upper == "NULL" || upper == "TRUE" || upper == "FALSE"
        || upper == "CURRENT_TIMESTAMP" || upper == "CURRENT_DATE" || upper == "CURRENT_TIME"
        || value.hasPrefix("(") || upper.hasPrefix("X'")
        || Int64(value) != nil || Double(value) != nil
        || libSQLWholeStringLiteral(value) != nil {
        return value
    }
    return libSQLLooksLikeExpression(value) ? "(\(value))" : "'\(libSQLDefaultLiteralEscape(value))'"
}

/// Whether the fragment is one whole single-quoted literal rather than an expression that happens
/// to start with a quote.
internal func libSQLWholeStringLiteral(_ value: String) -> String? {
    guard value.count >= 2, value.hasPrefix("\'"), value.hasSuffix("\'") else { return nil }
    let inner = String(value.dropFirst().dropLast())
    var result = ""
    var index = inner.startIndex
    while index < inner.endIndex {
        let character = inner[index]
        let next = inner.index(after: index)
        guard character == "\'" else {
            result.append(character)
            index = next
            continue
        }
        guard next < inner.endIndex, inner[next] == "\'" else { return nil }
        result.append("\'")
        index = inner.index(after: next)
    }
    return result
}

private let libSQLExpressionCharacters: Set<Character> = ["(", ")", "|", "+", "-", "*", "/", "%", "<", ">", "=", "!", "~", "&", " ", ","]

internal func libSQLLooksLikeExpression(_ value: String) -> Bool {
    value.contains { libSQLExpressionCharacters.contains($0) }
}

internal func libSQLDefaultLiteralEscape(_ value: String) -> String {
    value.replacingOccurrences(of: "\'", with: "\'\'")
}
