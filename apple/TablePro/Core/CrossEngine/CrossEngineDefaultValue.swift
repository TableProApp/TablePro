//
//  CrossEngineDefaultValue.swift
//  TablePro
//
//  What a column's default becomes on the other engine.
//
//  A default is the exact SQL that follows the source's own `DEFAULT` keyword,
//  and the target's DDL writer emits what it is given verbatim. So a default
//  this cannot translate must be dropped with a reason rather than passed on:
//  passed on, it reaches the server as the source's dialect and either breaks
//  the CREATE TABLE or means something else there.
//
//  `nextval(...)` is the one that is not a default at all. PostgreSQL renders a
//  `SERIAL` as an ordinary integer whose default calls its sequence, and the
//  sequence is a separate object written in PostgreSQL's DDL. Copied across
//  engines the sequence cannot come with it, so the default becomes the target's
//  own auto-increment instead, which is what a `SERIAL` meant in the first place.
//

import Foundation
import TableProSQLQuoting

internal enum CrossEngineDefaultValue {
    internal enum Outcome: Equatable, Sendable {
        case none
        case keep(String)
        /// The column carries the target's own generated-key attribute and no default text.
        case autoIncrement
        case drop(reason: String)
    }

    internal static func translate(
        _ value: String?,
        kind: CanonicalTypeKind,
        to target: SQLTypeFamily
    ) -> Outcome {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .none
        }
        let stripped = strippingCast(raw)
        let upper = stripped.uppercased()

        if upper.hasPrefix("NEXTVAL(") { return .autoIncrement }
        if upper == "NULL" { return .none }
        if let now = currentTimestamp(upper, target: target) { return .keep(now) }
        if let today = currentDate(upper, target: target) { return .keep(today) }
        if let boolean = booleanLiteral(upper, kind: kind, target: target) { return .keep(boolean) }
        if isNumericLiteral(stripped) { return .keep(stripped) }
        if let literal = stringLiteral(stripped) { return .keep(literal) }

        return .drop(reason: String(
            format: String(localized: "The default %@ is not written in a form this engine shares."),
            raw
        ))
    }

    // MARK: - Shapes

    // PostgreSQL writes a default's type onto it, `'active'::character varying`, which no other engine reads. Only a
    // cast that ends the expression goes, found by scalar: a quote a combining mark follows is one Character.
    internal static func strippingCast(_ value: String) -> String {
        guard let range = value.range(of: "::", options: .literal) else { return value }
        let head = String(value[value.startIndex..<range.lowerBound])
        let tail = value[range.upperBound...].unicodeScalars
        guard !tail.contains("'"), !tail.contains("("), !head.isEmpty else { return value }
        return head.trimmingCharacters(in: .whitespaces)
    }

    // A default built on the current date or time, UTC forms and time zone conversions included.
    internal static func readsTheClock(_ value: String) -> Bool {
        let upper = value.uppercased()
        return clockNames.contains { upper.contains($0) }
    }

    private static let clockNames = [
        "NOW(", "CURRENT_TIMESTAMP", "LOCALTIMESTAMP", "CURRENT_DATE", "CURDATE(", "CURTIME(", "TODAY(",
        "GETDATE(", "GETUTCDATE(", "SYSDATETIME(", "SYSUTCDATETIME(", "SYSDATETIMEOFFSET(", "UTC_TIMESTAMP",
        "SYSDATE", "SYSTIMESTAMP", "STATEMENT_TIMESTAMP(", "TRANSACTION_TIMESTAMP(", "CLOCK_TIMESTAMP(",
    ]

    private static func currentTimestamp(_ upper: String, target: SQLTypeFamily) -> String? {
        let names = [
            "CURRENT_TIMESTAMP", "CURRENT_TIMESTAMP()", "NOW()", "GETDATE()", "GETUTCDATE()",
            "SYSDATETIME()", "SYSDATE", "SYSTIMESTAMP", "LOCALTIMESTAMP", "LOCALTIMESTAMP()",
            "STATEMENT_TIMESTAMP()", "TRANSACTION_TIMESTAMP()", "CLOCK_TIMESTAMP()"
        ]
        let matches = names.contains(upper) || upper.hasPrefix("CURRENT_TIMESTAMP(")
        guard matches else { return nil }
        return target == .clickhouse ? "now()" : "CURRENT_TIMESTAMP"
    }

    private static func currentDate(_ upper: String, target: SQLTypeFamily) -> String? {
        guard ["CURRENT_DATE", "CURRENT_DATE()", "CURDATE()", "TODAY()"].contains(upper) else { return nil }
        return target == .clickhouse ? "today()" : "CURRENT_DATE"
    }

    /// Every engine spells a boolean default differently and half of them have no boolean type at
    /// all, so the literal follows the target rather than the source. PostgreSQL reports a `false`
    /// default on a `boolean` column as `false`, and MySQL stores it in a `TINYINT(1)` as 0.
    private static func booleanLiteral(
        _ upper: String,
        kind: CanonicalTypeKind,
        target: SQLTypeFamily
    ) -> String? {
        guard case .boolean = kind else { return nil }
        let isTrue = ["TRUE", "'T'", "T", "1", "'1'", "YES", "'YES'", "B'1'"].contains(upper)
        let isFalse = ["FALSE", "'F'", "F", "0", "'0'", "NO", "'NO'", "B'0'"].contains(upper)
        guard isTrue || isFalse else { return nil }
        switch target {
        case .postgres, .duckdb:
            return isTrue ? "TRUE" : "FALSE"
        case .clickhouse:
            return isTrue ? "true" : "false"
        case .mysql, .sqlite, .mssql, .oracle, .generic:
            return isTrue ? "1" : "0"
        }
    }

    private static func isNumericLiteral(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return Int64(value) != nil || Double(value) != nil
    }

    // One whole quoted literal, which every engine here writes the same way. A backslash escape is MySQL's alone, so a
    // literal holding a backslash is dropped.
    private static func stringLiteral(_ value: String) -> String? {
        guard !value.unicodeScalars.contains("\\"), SQLQuoting.decodedStringLiteral(value) != nil else { return nil }
        return value
    }
}
