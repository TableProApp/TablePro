//
//  SQLTypeRenderer+RegistryFamilies.swift
//  TablePro
//
//  SQL Server, Oracle, ClickHouse and DuckDB as copy targets, and the ANSI
//  spellings used for an engine no family names.
//

import Foundation

internal extension SQLTypeRenderer {
    // MARK: - SQL Server

    static func mssql(_ type: CanonicalColumnType) -> RenderedColumnType {
        switch type.kind {
        case .boolean:
            return RenderedColumnType(spelling: "BIT")
        case .integer(let bytes):
            return mssqlInteger(bytes: bytes, isUnsigned: type.isUnsigned)
        case .decimal(let precision, let scale):
            return decimalSpelling(
                "DECIMAL", precision: precision, scale: scale, precisionCeiling: 38
            )
        case .floatingPoint(let bits):
            return RenderedColumnType(spelling: bits <= 32 ? "REAL" : "FLOAT")
        case .text(let length, let isFixed):
            return mssqlText(length: length, isFixed: isFixed)
        case .binary(let length, let isFixed):
            guard let length, length <= 8_000 else {
                return RenderedColumnType(spelling: "VARBINARY(MAX)")
            }
            return RenderedColumnType(spelling: isFixed ? "BINARY(\(length))" : "VARBINARY(\(length))")
        case .date:
            return RenderedColumnType(spelling: "DATE")
        case .time(let precision, let hasTimeZone):
            return RenderedColumnType(
                spelling: "TIME" + precisionSuffix(precision),
                fidelity: hasTimeZone ? .approximated : .exact,
                reason: hasTimeZone ? timeZoneDropped : nil
            )
        case .timestamp(let precision, let hasTimeZone):
            let base = hasTimeZone ? "DATETIMEOFFSET" : "DATETIME2"
            return RenderedColumnType(spelling: base + precisionSuffix(precision))
        case .interval:
            return RenderedColumnType(
                spelling: "NVARCHAR(64)", fidelity: .approximated,
                reason: noEquivalent("INTERVAL", as: "NVARCHAR(64)")
            )
        case .uuid:
            return RenderedColumnType(spelling: "UNIQUEIDENTIFIER")
        case .json:
            return RenderedColumnType(
                spelling: "NVARCHAR(MAX)", fidelity: .widened, reason: widenedTo("NVARCHAR(MAX)")
            )
        case .xml:
            return RenderedColumnType(spelling: "XML")
        case .enumeration(let values):
            return RenderedColumnType(
                spelling: "NVARCHAR(\(longestLabel(in: values)))",
                fidelity: .approximated, reason: enumBecomesText
            )
        case .bitString(let length):
            return RenderedColumnType(
                spelling: "VARBINARY(\(max(1, ((length ?? 1) + 7) / 8)))",
                fidelity: .widened, reason: widenedTo("VARBINARY")
            )
        case .money:
            return RenderedColumnType(spelling: "MONEY")
        case .spatial, .array, .unsupported:
            return RenderedColumnType(
                spelling: "NVARCHAR(MAX)", fidelity: .approximated,
                reason: noEquivalent(type.sourceSpelling, as: "NVARCHAR(MAX)")
            )
        }
    }

    /// `TINYINT` on SQL Server is unsigned and holds 0 to 255, so a signed one-byte source widens
    /// to `SMALLINT`. Left as `TINYINT`, every negative value in the column fails on insert.
    private static func mssqlInteger(bytes: Int, isUnsigned: Bool) -> RenderedColumnType {
        if bytes <= 1, isUnsigned { return RenderedColumnType(spelling: "TINYINT") }
        let effective = isUnsigned ? bytes * 2 : max(bytes, 2)
        switch effective {
        case ...2: return RenderedColumnType(spelling: "SMALLINT")
        case 3...4: return RenderedColumnType(spelling: "INT")
        case 5...8: return RenderedColumnType(spelling: "BIGINT")
        default:
            let digits = decimalDigits(forIntegerBytes: bytes, isUnsigned: isUnsigned, ceiling: 38)
            return RenderedColumnType(
                spelling: "DECIMAL(\(digits), 0)", fidelity: .widened,
                reason: widenedTo("DECIMAL(\(digits), 0)")
            )
        }
    }

    /// The `N` spellings throughout, so text that crossed from a UTF-8 engine is not narrowed to
    /// the server's own code page. A non-`N` `VARCHAR` on a Latin-1 collation drops every
    /// character outside it, and it drops them silently.
    private static func mssqlText(length: Int?, isFixed: Bool) -> RenderedColumnType {
        guard let length, length <= 4_000 else {
            return RenderedColumnType(
                spelling: "NVARCHAR(MAX)",
                fidelity: length == nil ? .exact : .widened,
                reason: length == nil ? nil : widenedTo("NVARCHAR(MAX)")
            )
        }
        return RenderedColumnType(spelling: isFixed ? "NCHAR(\(length))" : "NVARCHAR(\(length))")
    }

    // MARK: - Oracle

    static func oracle(_ type: CanonicalColumnType) -> RenderedColumnType {
        switch type.kind {
        /// Oracle had no `BOOLEAN` in SQL before 23ai, and `NUMBER(1)` is what every Oracle schema
        /// uses for one. The value coercer writes 1 and 0 into it.
        case .boolean:
            return RenderedColumnType(
                spelling: "NUMBER(1)", fidelity: .approximated,
                reason: noEquivalent("BOOLEAN", as: "NUMBER(1)")
            )
        case .integer(let bytes):
            let digits = decimalDigits(forIntegerBytes: bytes, isUnsigned: type.isUnsigned, ceiling: 38)
            return RenderedColumnType(spelling: "NUMBER(\(digits))")
        case .decimal(let precision, let scale):
            return decimalSpelling(
                "NUMBER", precision: precision, scale: scale, precisionCeiling: 38
            )
        case .floatingPoint(let bits):
            return RenderedColumnType(spelling: bits <= 32 ? "BINARY_FLOAT" : "BINARY_DOUBLE")
        case .text(let length, let isFixed):
            return oracleText(length: length, isFixed: isFixed)
        case .binary(let length, _):
            guard let length, length <= 2_000 else { return RenderedColumnType(spelling: "BLOB") }
            return RenderedColumnType(spelling: "RAW(\(length))")
        case .date:
            return RenderedColumnType(spelling: "DATE")
        case .time(let precision, _):
            return RenderedColumnType(
                spelling: "INTERVAL DAY(0) TO SECOND\(precisionSuffix(precision))",
                fidelity: .approximated, reason: noEquivalent("TIME", as: "INTERVAL DAY TO SECOND")
            )
        case .timestamp(let precision, let hasTimeZone):
            let suffix = hasTimeZone ? " WITH TIME ZONE" : ""
            return RenderedColumnType(spelling: "TIMESTAMP" + precisionSuffix(precision) + suffix)
        case .interval:
            return RenderedColumnType(spelling: "INTERVAL DAY TO SECOND")
        case .uuid:
            return RenderedColumnType(
                spelling: "VARCHAR2(36)", fidelity: .widened, reason: widenedTo("VARCHAR2(36)")
            )
        case .json:
            return RenderedColumnType(spelling: "CLOB", fidelity: .widened, reason: widenedTo("CLOB"))
        case .xml:
            return RenderedColumnType(spelling: "XMLTYPE")
        case .enumeration(let values):
            return RenderedColumnType(
                spelling: "VARCHAR2(\(longestLabel(in: values)))",
                fidelity: .approximated, reason: enumBecomesText
            )
        case .money:
            return RenderedColumnType(spelling: "NUMBER(19, 4)")
        case .bitString, .spatial, .array, .unsupported:
            return RenderedColumnType(
                spelling: "CLOB", fidelity: .approximated,
                reason: noEquivalent(type.sourceSpelling, as: "CLOB")
            )
        }
    }

    private static func oracleText(length: Int?, isFixed: Bool) -> RenderedColumnType {
        if isFixed, let length, length <= 2_000 {
            return RenderedColumnType(spelling: "CHAR(\(length))")
        }
        guard let length, length <= 4_000 else {
            return RenderedColumnType(
                spelling: "CLOB",
                fidelity: length == nil ? .exact : .widened,
                reason: length == nil ? nil : widenedTo("CLOB")
            )
        }
        return RenderedColumnType(spelling: "VARCHAR2(\(length))")
    }

    // MARK: - ClickHouse

    static func clickHouse(_ type: CanonicalColumnType) -> RenderedColumnType {
        switch type.kind {
        case .boolean:
            return RenderedColumnType(spelling: "Bool")
        case .integer(let bytes):
            let prefix = type.isUnsigned ? "UInt" : "Int"
            let bits: Int
            switch bytes {
            case ...1: bits = 8
            case 2: bits = 16
            case 3, 4: bits = 32
            case 8: bits = 64
            default: bits = 128
            }
            return RenderedColumnType(spelling: "\(prefix)\(bits)")
        case .decimal(let precision, let scale):
            return decimalSpelling(
                "Decimal", precision: precision, scale: scale, precisionCeiling: 76
            )
        case .floatingPoint(let bits):
            return RenderedColumnType(spelling: bits <= 32 ? "Float32" : "Float64")
        case .text(let length, let isFixed):
            guard isFixed, let length else { return RenderedColumnType(spelling: "String") }
            return RenderedColumnType(spelling: "FixedString(\(length))")
        case .binary:
            return RenderedColumnType(spelling: "String", fidelity: .widened, reason: widenedTo("String"))
        case .date:
            return RenderedColumnType(spelling: "Date32")
        case .timestamp(let precision, let hasTimeZone):
            let spelling = (precision ?? 0) > 0 ? "DateTime64(\(precision ?? 3))" : "DateTime64(3)"
            return RenderedColumnType(
                spelling: spelling, fidelity: hasTimeZone ? .approximated : .exact,
                reason: hasTimeZone ? timeZoneDropped : nil
            )
        case .uuid:
            return RenderedColumnType(spelling: "UUID")
        case .enumeration(let values):
            return clickHouseEnum(values)
        case .array(let element):
            let inner = clickHouse(CanonicalColumnType(
                kind: element, isUnsigned: type.isUnsigned, sourceSpelling: type.sourceSpelling
            ))
            return RenderedColumnType(
                spelling: "Array(\(inner.spelling))", fidelity: inner.fidelity, reason: inner.reason
            )
        case .time, .interval, .json, .xml, .bitString, .money, .spatial, .unsupported:
            return RenderedColumnType(
                spelling: "String", fidelity: .approximated,
                reason: noEquivalent(type.sourceSpelling, as: "String")
            )
        }
    }

    private static func clickHouseEnum(_ values: [String]) -> RenderedColumnType {
        guard !values.isEmpty, values.count <= 255 else {
            return RenderedColumnType(spelling: "String", fidelity: .approximated, reason: enumBecomesText)
        }
        let labels = values.enumerated()
            .map { "'\($0.element.replacingOccurrences(of: "'", with: "\\'"))' = \($0.offset + 1)" }
            .joined(separator: ", ")
        return RenderedColumnType(spelling: "Enum8(\(labels))")
    }

    // MARK: - DuckDB

    static func duckDB(_ type: CanonicalColumnType) -> RenderedColumnType {
        switch type.kind {
        case .boolean:
            return RenderedColumnType(spelling: "BOOLEAN")
        case .integer(let bytes):
            let prefix = type.isUnsigned ? "U" : ""
            switch bytes {
            case ...1: return RenderedColumnType(spelling: prefix + "TINYINT")
            case 2: return RenderedColumnType(spelling: prefix + "SMALLINT")
            case 3, 4: return RenderedColumnType(spelling: prefix + "INTEGER")
            case 8: return RenderedColumnType(spelling: prefix + "BIGINT")
            default: return RenderedColumnType(spelling: prefix + "HUGEINT")
            }
        case .decimal(let precision, let scale):
            return decimalSpelling(
                "DECIMAL", precision: precision, scale: scale, precisionCeiling: 38
            )
        case .floatingPoint(let bits):
            return RenderedColumnType(spelling: bits <= 32 ? "FLOAT" : "DOUBLE")
        case .text(let length, _):
            guard let length else { return RenderedColumnType(spelling: "VARCHAR") }
            return RenderedColumnType(spelling: "VARCHAR(\(length))")
        case .binary:
            return RenderedColumnType(spelling: "BLOB")
        case .date:
            return RenderedColumnType(spelling: "DATE")
        case .time(_, let hasTimeZone):
            return RenderedColumnType(spelling: hasTimeZone ? "TIMETZ" : "TIME")
        case .timestamp(_, let hasTimeZone):
            return RenderedColumnType(spelling: hasTimeZone ? "TIMESTAMPTZ" : "TIMESTAMP")
        case .interval:
            return RenderedColumnType(spelling: "INTERVAL")
        case .uuid:
            return RenderedColumnType(spelling: "UUID")
        case .json:
            return RenderedColumnType(spelling: "JSON")
        case .bitString:
            return RenderedColumnType(spelling: "BIT")
        case .money:
            return RenderedColumnType(spelling: "DECIMAL(19, 4)")
        case .array(let element):
            let inner = duckDB(CanonicalColumnType(
                kind: element, isUnsigned: type.isUnsigned, sourceSpelling: type.sourceSpelling
            ))
            return RenderedColumnType(
                spelling: "\(inner.spelling)[]", fidelity: inner.fidelity, reason: inner.reason
            )
        case .enumeration:
            return RenderedColumnType(spelling: "VARCHAR", fidelity: .approximated, reason: enumBecomesText)
        case .xml, .spatial, .unsupported:
            return RenderedColumnType(
                spelling: "VARCHAR", fidelity: .approximated,
                reason: noEquivalent(type.sourceSpelling, as: "VARCHAR")
            )
        }
    }

    // MARK: - ANSI

    /// What an engine no family names is given. Only words the SQL standard defines, because the
    /// next plugin to be copied into is not known here and a borrowed spelling would be a guess.
    static func ansi(_ type: CanonicalColumnType) -> RenderedColumnType {
        switch type.kind {
        case .boolean:
            return RenderedColumnType(spelling: "BOOLEAN")
        case .integer(let bytes):
            let effective = type.isUnsigned ? bytes * 2 : bytes
            switch effective {
            case ...2: return RenderedColumnType(spelling: "SMALLINT")
            case 3...4: return RenderedColumnType(spelling: "INTEGER")
            case 5...8: return RenderedColumnType(spelling: "BIGINT")
            default:
                let digits = decimalDigits(forIntegerBytes: bytes, isUnsigned: type.isUnsigned, ceiling: 38)
                return RenderedColumnType(
                    spelling: "DECIMAL(\(digits), 0)", fidelity: .widened,
                    reason: widenedTo("DECIMAL(\(digits), 0)")
                )
            }
        case .decimal(let precision, let scale):
            return decimalSpelling(
                "DECIMAL", precision: precision, scale: scale, precisionCeiling: 38
            )
        case .floatingPoint(let bits):
            return RenderedColumnType(spelling: bits <= 32 ? "REAL" : "DOUBLE PRECISION")
        case .text(let length, let isFixed):
            guard let length else { return RenderedColumnType(spelling: "TEXT") }
            return RenderedColumnType(spelling: isFixed ? "CHAR(\(length))" : "VARCHAR(\(length))")
        case .binary(let length, _):
            guard let length else { return RenderedColumnType(spelling: "BLOB") }
            return RenderedColumnType(spelling: "VARBINARY(\(length))")
        case .date:
            return RenderedColumnType(spelling: "DATE")
        case .time(let precision, let hasTimeZone):
            let suffix = hasTimeZone ? " WITH TIME ZONE" : ""
            return RenderedColumnType(spelling: "TIME" + precisionSuffix(precision) + suffix)
        case .timestamp(let precision, let hasTimeZone):
            let suffix = hasTimeZone ? " WITH TIME ZONE" : ""
            return RenderedColumnType(spelling: "TIMESTAMP" + precisionSuffix(precision) + suffix)
        case .money:
            return RenderedColumnType(spelling: "DECIMAL(19, 4)")
        case .uuid:
            return RenderedColumnType(spelling: "CHAR(36)", fidelity: .widened, reason: widenedTo("CHAR(36)"))
        case .interval, .json, .xml, .enumeration, .bitString, .spatial, .array, .unsupported:
            return RenderedColumnType(
                spelling: "TEXT", fidelity: .approximated,
                reason: noEquivalent(type.sourceSpelling, as: "TEXT")
            )
        }
    }
}
