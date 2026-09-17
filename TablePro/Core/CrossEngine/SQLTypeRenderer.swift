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
    internal static func render(
        _ type: CanonicalColumnType,
        family: SQLTypeFamily,
        jsonColumnType: PostgreSQLJSONColumnType = .jsonb
    ) -> RenderedColumnType {
        switch family {
        case .mysql: return mysql(type)
        case .postgres: return postgres(type, jsonColumnType: jsonColumnType)
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
    ///
    /// A scale below zero or above the precision is PostgreSQL's, from 15, and Oracle's.
    /// `numeric(5,-2)` holds whole hundreds up to 9,999,900 and `numeric(3,5)` fractions under
    /// 0.01, and MySQL refuses both spellings, with ERROR 1064 and ERROR 1427. So the column takes
    /// the digits its values have on each side of the point, `DECIMAL(7, 0)` and `DECIMAL(5, 5)`,
    /// which hold every value and accept more. MySQL also keeps at most 30 digits after the point
    /// and refuses a larger scale with ERROR 1425, which is what `scaleCeiling` carries.
    internal static func decimalSpelling(
        _ name: String,
        precision: Int?,
        scale: Int?,
        precisionCeiling: Int,
        scaleCeiling: Int? = nil
    ) -> RenderedColumnType {
        guard let requested = precision else {
            return unconstrainedDecimal(name, precisionCeiling: precisionCeiling)
        }
        guard let scale else {
            let resolved = min(requested, precisionCeiling)
            return precisionCut("\(name)(\(resolved))", resolved: resolved, requested: requested)
        }

        let integerDigits = max(0, requested - scale)
        let fractionDigits = max(0, scale)
        let digits = integerDigits + fractionDigits
        let keptFraction = min(fractionDigits, scaleCeiling ?? precisionCeiling, precisionCeiling)
        guard digits <= precisionCeiling else {
            return precisionCut(
                "\(name)(\(precisionCeiling), \(keptFraction))", resolved: precisionCeiling, requested: digits
            )
        }
        guard keptFraction == fractionDigits else {
            return RenderedColumnType(
                spelling: "\(name)(\(integerDigits + keptFraction), \(keptFraction))",
                fidelity: .approximated,
                reason: String(
                    format: String(
                        localized: "The column keeps %1$lld of its %2$lld digits after the point, so a longer fraction is rounded."
                    ),
                    keptFraction, fractionDigits
                )
            )
        }
        let spelling = "\(name)(\(digits), \(fractionDigits))"
        guard scale < 0 || scale > requested else { return RenderedColumnType(spelling: spelling) }
        return RenderedColumnType(spelling: spelling, fidelity: .widened, reason: widenedTo(spelling))
    }

    private static func precisionCut(_ spelling: String, resolved: Int, requested: Int) -> RenderedColumnType {
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

    /// A decimal with no declared limit, on an engine whose decimals all have one.
    ///
    /// The engine's widest, with room for 20 digits before the point so every 64-bit integer fits,
    /// and at most 30 after it, which is MySQL's ceiling and more than the 20 PostgreSQL's own
    /// division produces. A narrower guess rounds silently: MariaDB stores `1234.56` in a
    /// `DECIMAL(38)` as `1235` with only a note, even in strict mode.
    internal static func unconstrainedDecimal(_ name: String, precisionCeiling: Int) -> RenderedColumnType {
        let scale = min(30, precisionCeiling - 20)
        return RenderedColumnType(
            spelling: "\(name)(\(precisionCeiling), \(scale))",
            fidelity: .approximated,
            reason: String(
                format: String(
                    localized: "With no precision on the source, the column keeps %1$lld digits, %2$lld after the point. A value with more is rounded or refused."
                ),
                precisionCeiling, scale
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
