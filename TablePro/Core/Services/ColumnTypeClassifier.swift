//
//  ColumnTypeClassifier.swift
//  TablePro
//
//  Maps raw database type strings to semantic ColumnType values.
//  Handles type wrappers (Nullable, LowCardinality), parameterized types,
//  and database-specific conventions across all supported databases.
//

import Foundation

struct ColumnTypeClassifier {

    func classify(rawTypeName: String) -> ColumnType {
        let stripped = stripWrappers(rawTypeName)
        let (base, params) = extractBaseAndParams(stripped)
        let upper = base.uppercased()

        // MySQL convention: TINYINT(1) means boolean
        if upper == "TINYINT", params == "1" {
            return .boolean(rawType: rawTypeName)
        }

        if let factory = Self.typeLookup[upper] {
            return factory(rawTypeName)
        }

        return classifyByPattern(upper: upper, rawTypeName: rawTypeName)
    }

    // MARK: - Wrapper Stripping

    private func stripWrappers(_ value: String) -> String {
        for prefix in ["Nullable(", "LowCardinality("] {
            if value.hasPrefix(prefix), value.hasSuffix(")") {
                let startIndex = value.index(value.startIndex, offsetBy: prefix.count)
                let endIndex = value.index(before: value.endIndex)
                let inner = String(value[startIndex..<endIndex])
                return stripWrappers(inner)
            }
        }
        return value
    }

    // MARK: - Base / Params Extraction

    private func extractBaseAndParams(_ value: String) -> (base: String, params: String?) {
        guard let parenIndex = value.firstIndex(of: "(") else {
            return (value, nil)
        }
        let base = String(value[value.startIndex..<parenIndex])
        guard let lastParen = value.lastIndex(of: ")") else {
            return (value, nil)
        }
        let paramsStart = value.index(after: parenIndex)
        let params = String(value[paramsStart..<lastParen]).trimmingCharacters(in: .whitespaces)
        return (base, params)
    }

    // MARK: - Pattern Fallback

    private func classifyByPattern(upper: String, rawTypeName: String) -> ColumnType {
        if upper.contains("BOOL") {
            return .boolean(rawType: rawTypeName)
        }
        if upper.hasSuffix("SERIAL") {
            return .integer(rawType: rawTypeName)
        }
        if upper.hasSuffix("INT") {
            return .integer(rawType: rawTypeName)
        }
        if upper.hasPrefix("TIMESTAMP") {
            return .timestamp(rawType: rawTypeName)
        }
        if upper.hasSuffix("TEXT") || upper.hasSuffix("CHAR") {
            return .text(rawType: rawTypeName)
        }
        if upper.contains("BLOB") {
            return .blob(rawType: rawTypeName)
        }
        if upper.hasPrefix("ENUM") {
            return .enumType(rawType: rawTypeName, values: nil)
        }
        if upper.hasPrefix("SET(") {
            return .set(rawType: rawTypeName, values: nil)
        }
        return .text(rawType: rawTypeName)
    }

    // MARK: - Type Lookup Table

    // swiftlint:disable:next function_body_length
    private static let typeLookup: [String: (String) -> ColumnType] = {
        var map: [String: (String) -> ColumnType] = [:]

        // Boolean
        for key in ["BOOL", "BOOLEAN", "BIT"] {
            map[key] = { .boolean(rawType: $0) }
        }

        // Integer
        for key in [
            "INT", "INTEGER", "BIGINT", "SMALLINT", "TINYINT", "MEDIUMINT",
            "SERIAL", "BIGSERIAL", "SMALLSERIAL",
            "INT2", "INT4",
            "INT8", "INT16", "INT32", "INT64", "INT128", "INT256",
            "UINT8", "UINT16", "UINT32", "UINT64", "UINT128", "UINT256",
            "UTINYINT", "USMALLINT", "UINTEGER", "UBIGINT", "HUGEINT", "UHUGEINT"
        ] {
            map[key] = { .integer(rawType: $0) }
        }

        // Decimal
        for key in [
            "FLOAT", "DOUBLE", "DECIMAL", "NUMERIC", "REAL", "NUMBER",
            "MONEY", "SMALLMONEY",
            "FLOAT32", "FLOAT64",
            "DECIMAL32", "DECIMAL64", "DECIMAL128", "DECIMAL256",
            "BINARY_FLOAT", "BINARY_DOUBLE",
            "DOUBLE PRECISION"
        ] {
            map[key] = { .decimal(rawType: $0) }
        }

        // Date
        for key in ["DATE", "DATE32"] {
            map[key] = { .date(rawType: $0) }
        }

        // Timestamp
        for key in [
            "TIMESTAMP", "TIMESTAMPTZ", "TIMESTAMP_TZ", "TIMESTAMP_NTZ",
            "TIMESTAMP_S", "TIMESTAMP_MS", "TIMESTAMP_NS",
            "TIME", "TIMETZ"
        ] {
            map[key] = { .timestamp(rawType: $0) }
        }

        // Datetime
        for key in [
            "DATETIME", "DATETIME2", "DATETIME64",
            "DATETIMEOFFSET", "SMALLDATETIME"
        ] {
            map[key] = { .datetime(rawType: $0) }
        }

        // JSON
        for key in ["JSON", "JSONB"] {
            map[key] = { .json(rawType: $0) }
        }

        // Blob
        for key in [
            "BLOB", "BYTEA", "BINARY", "VARBINARY", "RAW", "IMAGE",
            "TINYBLOB", "MEDIUMBLOB", "LONGBLOB"
        ] {
            map[key] = { .blob(rawType: $0) }
        }

        // Enum
        for key in ["ENUM", "ENUM8", "ENUM16"] {
            map[key] = { .enumType(rawType: $0, values: nil) }
        }

        // Set
        map["SET"] = { .set(rawType: $0, values: nil) }

        // Spatial
        for key in [
            "GEOMETRY", "POINT", "LINESTRING", "POLYGON",
            "MULTIPOINT", "MULTILINESTRING", "MULTIPOLYGON",
            "GEOGRAPHY", "GEOMETRYCOLLECTION"
        ] {
            map[key] = { .spatial(rawType: $0) }
        }

        // Text (explicit entries for common types not caught by fallback)
        for key in [
            "TEXT", "VARCHAR", "CHAR", "NVARCHAR", "NCHAR", "NTEXT",
            "VARCHAR2", "CLOB", "NCLOB",
            "STRING", "FIXEDSTRING",
            "UUID", "UNIQUEIDENTIFIER", "SQL_VARIANT",
            "TINYTEXT", "MEDIUMTEXT", "LONGTEXT"
        ] {
            map[key] = { .text(rawType: $0) }
        }

        return map
    }()
}
