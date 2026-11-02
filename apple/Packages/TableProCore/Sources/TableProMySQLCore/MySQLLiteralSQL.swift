import Foundation
import TableProSQLQuoting

// The plugin's own spelling, which `MySQLLiteralSpelling.respelled` turns into the session's.
nonisolated public func mysqlEscapeStringLiteral(_ value: String) -> String {
    SQLQuoting.stringLiteralBody(value, escapes: .mysql)
}

/// MySQL rejects a CURRENT_TIMESTAMP expression whose fractional-second precision differs
/// from the column's own, so the precision is always taken from the declared type.
nonisolated public func mysqlFractionalSecondsSuffix(forDataType dataType: String) -> String {
    let upper = dataType.uppercased()
    guard upper.hasPrefix("TIMESTAMP(") || upper.hasPrefix("DATETIME(") else { return "" }
    guard let open = dataType.firstIndex(of: "("),
          let close = dataType[open...].firstIndex(of: ")") else { return "" }
    return String(dataType[open...close])
}

nonisolated public func mysqlCurrentTimestampExpression(_ value: String, dataType: String) -> String? {
    let upper = value.uppercased()
    guard upper == "CURRENT_TIMESTAMP" || upper == "CURRENT_TIMESTAMP()"
        || upper.hasPrefix("CURRENT_TIMESTAMP(") else { return nil }
    return "CURRENT_TIMESTAMP" + mysqlFractionalSecondsSuffix(forDataType: dataType)
}

/// The only types on which a bare `CURRENT_TIMESTAMP` is the temporal expression rather than the
/// seventeen-character string. On a `VARCHAR`, MySQL reports a literal of that text the same way and
/// with no `DEFAULT_GENERATED` marker, so reading it as the expression turns a stored string into a
/// clock reading on the next edit to the column.
nonisolated public func mysqlTemporalType(_ dataType: String) -> Bool {
    let base = dataType.uppercased().split(separator: "(", maxSplits: 1).first.map(String.init)?
        .trimmingCharacters(in: .whitespaces) ?? dataType.uppercased()
    return base == "TIMESTAMP" || base == "DATETIME"
}
