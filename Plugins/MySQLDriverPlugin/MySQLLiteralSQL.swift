//
//  MySQLLiteralSQL.swift
//  MySQLDriverPlugin
//
//  The literal spellings the column default reader and the DDL writers share. Foundation only, so
//  the iOS app compiles it alongside the reader.
//

import Foundation

/// A form feed is written as itself: MySQL and MariaDB have no `\f` escape and read one as the
/// letter `f`, measured on MySQL 8.4 and MariaDB 13.
nonisolated internal func mysqlEscapeStringLiteral(_ value: String) -> String {
    var result = value
    result = result.replacingOccurrences(of: "\\", with: "\\\\")
    result = result.replacingOccurrences(of: "'", with: "''")
    result = result.replacingOccurrences(of: "\n", with: "\\n")
    result = result.replacingOccurrences(of: "\r", with: "\\r")
    result = result.replacingOccurrences(of: "\t", with: "\\t")
    result = result.replacingOccurrences(of: "\0", with: "\\0")
    result = result.replacingOccurrences(of: "\u{08}", with: "\\b")
    result = result.replacingOccurrences(of: "\u{1A}", with: "\\Z")
    return result
}

/// MySQL rejects a CURRENT_TIMESTAMP expression whose fractional-second precision differs
/// from the column's own, so the precision is always taken from the declared type.
nonisolated internal func mysqlFractionalSecondsSuffix(forDataType dataType: String) -> String {
    let upper = dataType.uppercased()
    guard upper.hasPrefix("TIMESTAMP(") || upper.hasPrefix("DATETIME(") else { return "" }
    guard let open = dataType.firstIndex(of: "("),
          let close = dataType[open...].firstIndex(of: ")") else { return "" }
    return String(dataType[open...close])
}

nonisolated internal func mysqlCurrentTimestampExpression(_ value: String, dataType: String) -> String? {
    let upper = value.uppercased()
    guard upper == "CURRENT_TIMESTAMP" || upper == "CURRENT_TIMESTAMP()"
        || upper.hasPrefix("CURRENT_TIMESTAMP(") else { return nil }
    return "CURRENT_TIMESTAMP" + mysqlFractionalSecondsSuffix(forDataType: dataType)
}

/// The only types on which a bare `CURRENT_TIMESTAMP` is the temporal expression rather than the
/// seventeen-character string. On a `VARCHAR`, MySQL reports a literal of that text the same way and
/// with no `DEFAULT_GENERATED` marker, so reading it as the expression turns a stored string into a
/// clock reading on the next edit to the column.
nonisolated internal func mysqlTemporalType(_ dataType: String) -> Bool {
    let base = dataType.uppercased().split(separator: "(", maxSplits: 1).first.map(String.init)?
        .trimmingCharacters(in: .whitespaces) ?? dataType.uppercased()
    return base == "TIMESTAMP" || base == "DATETIME"
}
