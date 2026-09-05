//
//  SQLTypeRenderer.swift
//  TablePro
//
//  Writes a canonical type in the target engine's own words.
//
//  Every family answers every kind. There is no "this engine cannot hold that"
//  arm, because a copy that drops a column is worse than a copy that says the
//  column arrived as text: the row is written either way, and only one of the
//  two tells the user what happened. So a kind with no equivalent is rendered
//  as the family's widest text type and carries the reason with it, which is
//  what the review step reads out before anything runs.
//
//  Widening is always toward the larger type. A MySQL `BIGINT UNSIGNED` becomes
//  a PostgreSQL `NUMERIC(20,0)` rather than a `BIGINT`, because half of its
//  range does not fit in one and the failure would be per row, at the end of a
//  long copy, on whichever row first exceeded it.
//

import Foundation

internal enum SQLTypeRenderer {
    internal static func render(_ type: CanonicalColumnType, family: SQLTypeFamily) -> RenderedColumnType {
        switch family {
        case .mysql: return mysql(type)
        case .postgres: return postgres(type)
        case .sqlite: return sqlite(type)
        case .mssql: return mssql(type)
        case .oracle: return oracle(type)
        case .clickhouse: return clickHouse(type)
        case .duckdb: return duckDB(type)
        case .generic: return ansi(type)
        }
    }

    // MARK: - Shared reasons

    internal static func noEquivalent(_ spelling: String, as substitute: String) -> String {
        String(
            format: String(localized: "%1$@ has no equivalent here, so the values arrive as %2$@."),
            spelling, substitute
        )
    }

    internal static var timeZoneDropped: String {
        String(localized: "The target has no time zone on this type, so the offset is dropped.")
    }

    internal static func widenedTo(_ substitute: String) -> String {
        String(format: String(localized: "Widened to %@, which holds every source value."), substitute)
    }

    internal static var enumBecomesText: String {
        String(localized: "The list of allowed values is not carried over.")
    }

    internal static var lengthNotEnforced: String {
        String(localized: "The declared length is kept for reference but is not enforced.")
    }

    // MARK: - Shared shapes

    /// A `DECIMAL` wide enough for that many bytes of integer, for a target with no integer type
    /// that wide. 16 bytes needs 39 digits, which is past what most engines allow, so the caller
    /// passes the ceiling its own engine accepts.
    internal static func decimalDigits(forIntegerBytes bytes: Int, isUnsigned: Bool, ceiling: Int) -> Int {
        let digits: Int
        switch bytes {
        case ...1: digits = isUnsigned ? 3 : 3
        case 2: digits = 5
        case 3: digits = 8
        case 4: digits = 10
        case 8: digits = isUnsigned ? 20 : 19
        default: digits = 39
        }
        return min(digits, ceiling)
    }

    /// A cut precision is a narrowing and says so.
    ///
    /// MySQL allows 65 digits and SQL Server, Oracle and DuckDB allow 38, so a `DECIMAL(65, 30)`
    /// crossing to any of them loses 27 of them. Reported as exact, the review step said nothing
    /// and the copy failed part way through the data phase on the first row that needed the digits
    /// the target no longer had.
    internal static func decimalSpelling(
        _ name: String,
        precision: Int?,
        scale: Int?,
        precisionCeiling: Int
    ) -> RenderedColumnType {
        let requested = precision ?? 38
        let resolved = min(requested, precisionCeiling)
        let spelling: String
        if let scale {
            spelling = "\(name)(\(resolved), \(min(scale, resolved)))"
        } else {
            spelling = "\(name)(\(resolved))"
        }
        guard resolved < requested else { return RenderedColumnType(spelling: spelling) }
        return RenderedColumnType(
            spelling: spelling,
            fidelity: .approximated,
            reason: String(
                format: String(
                    localized: "This engine holds %1$lld digits, not %2$lld, so the extra ones are lost."
                ),
                resolved, requested
            )
        )
    }

    /// A parenthesised precision only where the engine accepts one and the source had a real
    /// value. Rendering `TIMESTAMP(0)` where the source said nothing changes a column that would
    /// have kept fractional seconds into one that truncates them.
    internal static func precisionSuffix(_ precision: Int?) -> String {
        guard let precision, precision > 0 else { return "" }
        return "(\(precision))"
    }

    internal static func longestLabel(in values: [String]) -> Int {
        max(1, values.map { ($0 as NSString).length }.max() ?? 0)
    }
}
