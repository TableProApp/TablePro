//
//  SQLTypeParser.swift
//  TablePro
//
//  Reads one engine's spelling of a column type into the canonical vocabulary.
//
//  Every reading is family-specific even where the word is shared, because the
//  same word means different things: Oracle's `DATE` carries a time and
//  PostgreSQL's does not, MySQL's `TINYINT(1)` is a boolean and SQL Server's
//  `TINYINT` is an unsigned byte, and `REAL` is 32 bits on PostgreSQL and 64 on
//  SQLite. A shared table keyed on the word alone would get each of those
//  backwards for one of the two engines.
//
//  A word no family here knows becomes `.unsupported` carrying the source's own
//  spelling. That is not a failure: the renderer turns it into the target's
//  widest text type and the review step names it, which is what lets a copy
//  carry a PostGIS geometry or a ClickHouse tuple across as text rather than
//  refusing the whole table.
//

import Foundation

internal enum SQLTypeParser {
    internal static func parse(_ spelling: String, family: SQLTypeFamily) -> CanonicalColumnType {
        let trimmed = spelling.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return CanonicalColumnType(kind: .unsupported, sourceSpelling: spelling)
        }

        var body = stripWrappers(trimmed, family: family)
        let unsigned = hasUnsignedModifier(body)
        if unsigned { body = removingModifiers(body) }

        if let element = arrayElement(of: body, family: family) {
            let inner = parse(element, family: family)
            return CanonicalColumnType(
                kind: .array(element: inner.kind), isUnsigned: inner.isUnsigned, sourceSpelling: spelling
            )
        }

        let (base, params) = split(body)
        let kind = kind(base: base.uppercased(), params: params, family: family)
        return CanonicalColumnType(
            kind: kind, isUnsigned: unsigned || impliesUnsigned(base: base.uppercased(), family: family),
            sourceSpelling: spelling
        )
    }

    // MARK: - Shape

    /// ClickHouse writes nullability and its dictionary encoding into the type itself, and both
    /// wrap whatever they qualify. Read without stripping them, every ClickHouse column is one
    /// unknown type called `Nullable`.
    private static func stripWrappers(_ value: String, family: SQLTypeFamily) -> String {
        guard family == .clickhouse else { return value }
        for prefix in ["Nullable(", "LowCardinality("] where value.hasPrefix(prefix) && value.hasSuffix(")") {
            let inner = value.dropFirst(prefix.count).dropLast()
            return stripWrappers(String(inner), family: family)
        }
        return value
    }

    private static func hasUnsignedModifier(_ value: String) -> Bool {
        value.range(of: "\\bUNSIGNED\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// MySQL hangs `UNSIGNED`, `ZEROFILL` and a character set off the type itself, and SQL Server
    /// and Oracle hang a collation off theirs. None of them is part of the type name, and a base
    /// left holding one matches nothing in the family table.
    private static func removingModifiers(_ value: String) -> String {
        let pattern = "\\s+(UNSIGNED|ZEROFILL)\\b"
        return value
            .replacingOccurrences(
                of: pattern, with: "", options: [.regularExpression, .caseInsensitive]
            )
            .trimmingCharacters(in: .whitespaces)
    }

    private static func arrayElement(of value: String, family: SQLTypeFamily) -> String? {
        if value.hasSuffix("[]") {
            let element = String(value.dropLast(2)).trimmingCharacters(in: .whitespaces)
            return element.isEmpty ? nil : element
        }
        guard family == .clickhouse || family == .duckdb else { return nil }
        for prefix in ["Array(", "ARRAY("] where value.uppercased().hasPrefix(prefix.uppercased())
            && value.hasSuffix(")") {
            let element = String(value.dropFirst(prefix.count).dropLast()).trimmingCharacters(in: .whitespaces)
            return element.isEmpty ? nil : element
        }
        return nil
    }

    private static func split(_ value: String) -> (base: String, params: String?) {
        guard let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")"), open < close else {
            return (value.trimmingCharacters(in: .whitespaces), nil)
        }
        let base = String(value[value.startIndex..<open]).trimmingCharacters(in: .whitespaces)
        let params = String(value[value.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
        /// The suffix matters on PostgreSQL and Oracle, where the parenthesised part sits in the
        /// middle: `timestamp(3) with time zone`, `interval day(2) to second(6)`.
        let suffix = String(value[value.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        guard !suffix.isEmpty else { return (base, params.isEmpty ? nil : params) }
        return ("\(base) \(suffix)", params.isEmpty ? nil : params)
    }

    // MARK: - Parameters

    internal static func integers(in params: String?) -> [Int] {
        guard let params else { return [] }
        return params.split(separator: ",").compactMap {
            Int($0.trimmingCharacters(in: .whitespaces))
        }
    }

    /// The labels of a MySQL `ENUM` or a ClickHouse `Enum8`, whose parameter list is quoted text
    /// rather than numbers. A ClickHouse label carries an `= 1` the value list does not need.
    internal static func labels(in params: String?) -> [String] {
        guard let params, !params.isEmpty else { return [] }
        var labels: [String] = []
        var current = ""
        var quote: Character?
        var isEscaped = false
        for character in params {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }
            switch character {
            case "\\" where quote != nil:
                isEscaped = true
            case "'", "\"":
                if quote == character {
                    quote = nil
                    labels.append(current)
                    current = ""
                } else if quote == nil {
                    quote = character
                    current = ""
                } else {
                    current.append(character)
                }
            default:
                if quote != nil { current.append(character) }
            }
        }
        return labels
    }

    // MARK: - Family readings

    private static func kind(base: String, params: String?, family: SQLTypeFamily) -> CanonicalTypeKind {
        switch family {
        case .mysql: return mysqlKind(base: base, params: params)
        case .postgres: return postgresKind(base: base, params: params)
        case .sqlite: return sqliteKind(base: base, params: params)
        case .mssql: return mssqlKind(base: base, params: params)
        case .oracle: return oracleKind(base: base, params: params)
        case .clickhouse: return clickHouseKind(base: base, params: params)
        case .duckdb: return duckDBKind(base: base, params: params)
        case .generic: return ansiKind(base: base, params: params)
        }
    }

    private static func impliesUnsigned(base: String, family: SQLTypeFamily) -> Bool {
        switch family {
        case .mssql: return base == "TINYINT"
        case .clickhouse, .duckdb: return base.uppercased().hasPrefix("U") && base.uppercased() != "UUID"
        default: return false
        }
    }

    internal static func length(_ params: String?) -> Int? { integers(in: params).first }

    internal static func decimalKind(_ params: String?) -> CanonicalTypeKind {
        let numbers = integers(in: params)
        return .decimal(precision: numbers.first, scale: numbers.count > 1 ? numbers[1] : nil)
    }
}
