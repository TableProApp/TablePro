//
//  CrossEngineDefaultValue.swift
//  TablePro
//
//  What a column's default becomes on the other engine.
//
//  A default is the source's own SQL text and the target's DDL writer quotes
//  whatever it does not recognise, so an untranslated `now()` does not fail: it
//  becomes the literal string `'now()'` in every row, which is worse than
//  failing because nothing reports it. Everything here is therefore either
//  translated to the target's own spelling or dropped with a reason.
//
//  `nextval(...)` is the one that is not a default at all. PostgreSQL renders a
//  `SERIAL` as an ordinary integer whose default calls its sequence, and the
//  sequence is a separate object written in PostgreSQL's DDL. Copied across
//  engines the sequence cannot come with it, so the default becomes the target's
//  own auto-increment instead, which is what a `SERIAL` meant in the first place.
//

import Foundation

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
        if upper == "NULL" { return .keep("NULL") }
        if let now = currentTimestamp(upper, target: target) { return .keep(now) }
        if let today = currentDate(upper, target: target) { return .keep(today) }
        if let boolean = booleanLiteral(upper, kind: kind, target: target) { return .keep(boolean) }
        if isNumericLiteral(stripped) { return .keep(stripped) }
        if let literal = stringLiteral(stripped) { return .keep(literal) }
        if isBareWord(stripped) { return .keep(stripped) }

        return .drop(reason: String(
            format: String(localized: "The default %@ is not written in a form this engine shares."),
            raw
        ))
    }

    // MARK: - Shapes

    /// PostgreSQL writes a default's type onto it: `'active'::character varying`, `0::numeric`,
    /// `'{}'::jsonb`. The cast is PostgreSQL's own syntax and every other engine rejects it, while
    /// the value in front of it is portable.
    internal static func strippingCast(_ value: String) -> String {
        guard let range = value.range(of: "::") else { return value }
        /// Only a cast that ends the expression. A `::` inside quotes is part of the value, and one
        /// in the middle of a larger expression means the expression is not a bare literal anyway.
        let head = String(value[value.startIndex..<range.lowerBound])
        let tail = String(value[range.upperBound...])
        guard !tail.contains("'"), !tail.contains("("), !head.isEmpty else { return value }
        return head.trimmingCharacters(in: .whitespaces)
    }

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

    /// A quoted literal, which every engine here writes the same way. A doubled quote inside is the
    /// escape all of them share; a backslash escape is MySQL's alone and is left to be dropped.
    private static func stringLiteral(_ value: String) -> String? {
        guard value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 else { return nil }
        guard !value.contains("\\") else { return nil }
        let inner = value.dropFirst().dropLast()
        var index = inner.startIndex
        while index < inner.endIndex {
            guard inner[index] == "'" else {
                index = inner.index(after: index)
                continue
            }
            let next = inner.index(after: index)
            guard next < inner.endIndex, inner[next] == "'" else { return nil }
            index = inner.index(after: next)
        }
        return value
    }

    /// MySQL reports a string default without its quotes, so `active` on a `VARCHAR` arrives as a
    /// bare word. Every target's DDL writer quotes an unrecognised word, which is the right answer
    /// for it; what must not reach them is a word with a bracket or a space in it, because that is
    /// an expression and quoting one turns it into a string.
    private static func isBareWord(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128 else { return false }
        return value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
    }
}
