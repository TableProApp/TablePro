//
//  SQLTypeRenderer+BundledFamilies.swift
//  TablePro
//
//  MySQL, PostgreSQL and SQLite as copy targets.
//

import Foundation

internal extension SQLTypeRenderer {
    // MARK: - MySQL

    /// `UNSIGNED` is never spelled here. It is a column attribute rather than part of the type name
    /// as far as `PluginColumnDefinition` is concerned, and `mysqlColumnAttributesSQL` writes it
    /// from `unsigned`, so putting it in the type as well produced `INT UNSIGNED UNSIGNED`.
    static func mysql(_ type: CanonicalColumnType) -> RenderedColumnType {
        switch type.kind {
        case .boolean:
            return RenderedColumnType(spelling: "TINYINT(1)")
        case .integer(let bytes):
            return mysqlInteger(bytes: bytes, isUnsigned: type.isUnsigned)
        case .decimal(let precision, let scale):
            return decimalSpelling(
                "DECIMAL", precision: precision, scale: scale, precisionCeiling: 65
            )
        case .floatingPoint(let bits):
            return RenderedColumnType(spelling: bits <= 32 ? "FLOAT" : "DOUBLE")
        case .text(let length, let isFixed):
            return mysqlText(length: length, isFixed: isFixed)
        case .binary(let length, let isFixed):
            return mysqlBinary(length: length, isFixed: isFixed)
        case .date:
            return RenderedColumnType(spelling: "DATE")
        case .time(let precision, let hasTimeZone):
            return RenderedColumnType(
                spelling: "TIME" + precisionSuffix(precision),
                fidelity: hasTimeZone ? .approximated : .exact,
                reason: hasTimeZone ? timeZoneDropped : nil
            )
        case .timestamp(let precision, let hasTimeZone):
            return RenderedColumnType(
                spelling: "DATETIME" + precisionSuffix(precision),
                fidelity: hasTimeZone ? .approximated : .exact,
                reason: hasTimeZone ? timeZoneDropped : nil
            )
        case .interval:
            return RenderedColumnType(
                spelling: "VARCHAR(64)", fidelity: .approximated,
                reason: noEquivalent("INTERVAL", as: "VARCHAR(64)")
            )
        case .uuid:
            return RenderedColumnType(
                spelling: "CHAR(36)", fidelity: .widened, reason: widenedTo("CHAR(36)")
            )
        case .json:
            return RenderedColumnType(spelling: "JSON")
        case .xml:
            return RenderedColumnType(
                spelling: "LONGTEXT", fidelity: .approximated, reason: noEquivalent("XML", as: "LONGTEXT")
            )
        case .enumeration(let values):
            return mysqlEnum(values)
        case .bitString(let length):
            let bits = length ?? 1
            guard bits <= 64 else {
                return RenderedColumnType(
                    spelling: "VARBINARY(\(max(1, (bits + 7) / 8)))", fidelity: .widened,
                    reason: widenedTo("VARBINARY")
                )
            }
            return RenderedColumnType(spelling: "BIT(\(bits))")
        case .money:
            return RenderedColumnType(
                spelling: "DECIMAL(19, 4)", fidelity: .widened, reason: widenedTo("DECIMAL(19, 4)")
            )
        case .spatial:
            return RenderedColumnType(
                spelling: "LONGTEXT", fidelity: .approximated,
                reason: noEquivalent(type.sourceSpelling, as: String(localized: "text"))
            )
        case .array:
            return RenderedColumnType(
                spelling: "JSON", fidelity: .approximated,
                reason: noEquivalent(type.sourceSpelling, as: "JSON")
            )
        case .unsupported:
            return RenderedColumnType(
                spelling: "LONGTEXT", fidelity: .approximated,
                reason: noEquivalent(type.sourceSpelling, as: String(localized: "text"))
            )
        }
    }

    private static func mysqlInteger(bytes: Int, isUnsigned: Bool) -> RenderedColumnType {
        switch bytes {
        case ...1: return RenderedColumnType(spelling: "TINYINT")
        case 2: return RenderedColumnType(spelling: "SMALLINT")
        case 3: return RenderedColumnType(spelling: "MEDIUMINT")
        case 4: return RenderedColumnType(spelling: "INT")
        case 8: return RenderedColumnType(spelling: "BIGINT")
        default:
            let digits = decimalDigits(forIntegerBytes: bytes, isUnsigned: isUnsigned, ceiling: 65)
            return RenderedColumnType(
                spelling: "DECIMAL(\(digits), 0)", fidelity: .widened,
                reason: widenedTo("DECIMAL(\(digits), 0)")
            )
        }
    }

    /// `LONGTEXT` rather than `TEXT` for anything unbounded, because `TEXT` holds 64 KB and a
    /// PostgreSQL `text` column holds a gigabyte. Truncation would be silent outside strict mode.
    private static func mysqlText(length: Int?, isFixed: Bool) -> RenderedColumnType {
        if isFixed, let length, length <= 255 {
            return RenderedColumnType(spelling: "CHAR(\(length))")
        }
        guard let length, length <= 4_000 else {
            return RenderedColumnType(
                spelling: "LONGTEXT",
                fidelity: length == nil ? .exact : .widened,
                reason: length == nil ? nil : widenedTo("LONGTEXT")
            )
        }
        return RenderedColumnType(spelling: "VARCHAR(\(length))")
    }

    private static func mysqlBinary(length: Int?, isFixed: Bool) -> RenderedColumnType {
        if isFixed, let length, length <= 255 {
            return RenderedColumnType(spelling: "BINARY(\(length))")
        }
        guard let length, length <= 4_000 else {
            return RenderedColumnType(
                spelling: "LONGBLOB",
                fidelity: length == nil ? .exact : .widened,
                reason: length == nil ? nil : widenedTo("LONGBLOB")
            )
        }
        return RenderedColumnType(spelling: "VARBINARY(\(length))")
    }

    private static func mysqlEnum(_ values: [String]) -> RenderedColumnType {
        guard !values.isEmpty else {
            return RenderedColumnType(spelling: "VARCHAR(255)", fidelity: .approximated, reason: enumBecomesText)
        }
        let labels = values
            .map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }
            .joined(separator: ", ")
        return RenderedColumnType(spelling: "ENUM(\(labels))")
    }

    // MARK: - PostgreSQL

    static func postgres(_ type: CanonicalColumnType) -> RenderedColumnType {
        switch type.kind {
        case .boolean:
            return RenderedColumnType(spelling: "BOOLEAN")
        case .integer(let bytes):
            return postgresInteger(bytes: bytes, isUnsigned: type.isUnsigned)
        case .decimal(let precision, let scale):
            return decimalSpelling(
                "NUMERIC", precision: precision, scale: scale, precisionCeiling: 1_000
            )
        case .floatingPoint(let bits):
            return RenderedColumnType(spelling: bits <= 32 ? "REAL" : "DOUBLE PRECISION")
        case .text(let length, let isFixed):
            guard let length else { return RenderedColumnType(spelling: "TEXT") }
            return RenderedColumnType(spelling: isFixed ? "CHAR(\(length))" : "VARCHAR(\(length))")
        case .binary(let length, _):
            return RenderedColumnType(
                spelling: "BYTEA",
                fidelity: length == nil ? .exact : .widened,
                reason: length == nil ? nil : widenedTo("BYTEA")
            )
        case .date:
            return RenderedColumnType(spelling: "DATE")
        case .time(let precision, let hasTimeZone):
            let base = hasTimeZone ? "TIMETZ" : "TIME"
            return RenderedColumnType(spelling: base + precisionSuffix(precision))
        case .timestamp(let precision, let hasTimeZone):
            let base = hasTimeZone ? "TIMESTAMPTZ" : "TIMESTAMP"
            return RenderedColumnType(spelling: base + precisionSuffix(precision))
        case .interval:
            return RenderedColumnType(spelling: "INTERVAL")
        case .uuid:
            return RenderedColumnType(spelling: "UUID")
        case .json:
            return RenderedColumnType(spelling: "JSONB")
        case .xml:
            return RenderedColumnType(spelling: "XML")
        case .enumeration(let values):
            return RenderedColumnType(
                spelling: "VARCHAR(\(longestLabel(in: values)))",
                fidelity: .approximated, reason: enumBecomesText
            )
        case .bitString(let length):
            guard let length else { return RenderedColumnType(spelling: "BIT VARYING") }
            return RenderedColumnType(spelling: "BIT(\(length))")
        /// Not `MONEY`, whose text form and rounding follow the server's `lc_monetary`, so the same
        /// copy produces different values on two servers.
        case .money:
            return RenderedColumnType(
                spelling: "NUMERIC(19, 4)", fidelity: .widened, reason: widenedTo("NUMERIC(19, 4)")
            )
        case .spatial:
            return RenderedColumnType(
                spelling: "TEXT", fidelity: .approximated,
                reason: noEquivalent(type.sourceSpelling, as: String(localized: "text"))
            )
        case .array(let element):
            let inner = postgres(CanonicalColumnType(
                kind: element, isUnsigned: type.isUnsigned, sourceSpelling: type.sourceSpelling
            ))
            return RenderedColumnType(spelling: "\(inner.spelling)[]", fidelity: inner.fidelity, reason: inner.reason)
        case .unsupported:
            return RenderedColumnType(
                spelling: "TEXT", fidelity: .approximated,
                reason: noEquivalent(type.sourceSpelling, as: String(localized: "text"))
            )
        }
    }

    /// PostgreSQL has no unsigned integers, so an unsigned source widens by one step and the widest
    /// becomes a `NUMERIC`. Kept as the same width, a `BIGINT UNSIGNED` above 2^63 fails on the row
    /// that first exceeds it, which on a long copy is minutes in.
    private static func postgresInteger(bytes: Int, isUnsigned: Bool) -> RenderedColumnType {
        let effective = isUnsigned ? bytes * 2 : bytes
        switch effective {
        case ...2: return RenderedColumnType(spelling: "SMALLINT")
        case 3...4: return RenderedColumnType(spelling: "INTEGER")
        case 5...8: return RenderedColumnType(spelling: "BIGINT")
        default:
            let digits = decimalDigits(forIntegerBytes: bytes, isUnsigned: isUnsigned, ceiling: 1_000)
            return RenderedColumnType(
                spelling: "NUMERIC(\(digits), 0)", fidelity: .widened,
                reason: widenedTo("NUMERIC(\(digits), 0)")
            )
        }
    }

    // MARK: - SQLite

    /// SQLite declares an affinity rather than a type and stores the spelling verbatim, so the
    /// spellings here are chosen for what TablePro and every other reader make of them rather than
    /// for what the engine enforces, which is nothing.
    static func sqlite(_ type: CanonicalColumnType) -> RenderedColumnType {
        switch type.kind {
        case .boolean:
            return RenderedColumnType(spelling: "BOOLEAN")
        case .integer:
            return RenderedColumnType(spelling: "INTEGER")
        case .decimal(let precision, let scale):
            return decimalSpelling(
                "NUMERIC", precision: precision, scale: scale, precisionCeiling: 38
            )
        case .floatingPoint:
            return RenderedColumnType(spelling: "REAL")
        case .text(let length, _):
            guard let length else { return RenderedColumnType(spelling: "TEXT") }
            return RenderedColumnType(spelling: "VARCHAR(\(length))", fidelity: .widened, reason: lengthNotEnforced)
        case .binary:
            return RenderedColumnType(spelling: "BLOB")
        case .date:
            return RenderedColumnType(spelling: "DATE")
        case .time(_, let hasTimeZone):
            return RenderedColumnType(
                spelling: "TIME", fidelity: hasTimeZone ? .approximated : .exact,
                reason: hasTimeZone ? timeZoneDropped : nil
            )
        case .timestamp(_, let hasTimeZone):
            return RenderedColumnType(
                spelling: "DATETIME", fidelity: hasTimeZone ? .approximated : .exact,
                reason: hasTimeZone ? timeZoneDropped : nil
            )
        case .money:
            return RenderedColumnType(spelling: "NUMERIC(19, 4)")
        case .uuid, .json, .xml, .interval, .bitString, .enumeration, .spatial, .array, .unsupported:
            return sqliteText(type)
        }
    }

    private static func sqliteText(_ type: CanonicalColumnType) -> RenderedColumnType {
        if case .enumeration = type.kind {
            return RenderedColumnType(spelling: "TEXT", fidelity: .approximated, reason: enumBecomesText)
        }
        return RenderedColumnType(
            spelling: "TEXT", fidelity: .approximated,
            reason: noEquivalent(type.sourceSpelling, as: "TEXT")
        )
    }
}
