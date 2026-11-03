//
//  DuckDBTypeRendering.swift
//  DuckDBDriverPlugin
//

import Foundation
import TableProSQLQuoting

enum DuckDBLogicalType: String, CaseIterable, Sendable {
    case boolean = "BOOLEAN"
    case tinyint = "TINYINT"
    case smallint = "SMALLINT"
    case integer = "INTEGER"
    case bigint = "BIGINT"
    case utinyint = "UTINYINT"
    case usmallint = "USMALLINT"
    case uinteger = "UINTEGER"
    case ubigint = "UBIGINT"
    case float = "FLOAT"
    case double = "DOUBLE"
    case decimal = "DECIMAL"
    case hugeint = "HUGEINT"
    case uhugeint = "UHUGEINT"
    case varchar = "VARCHAR"
    case blob = "BLOB"
    case date = "DATE"
    case time = "TIME"
    case timeNs = "TIME_NS"
    case interval = "INTERVAL"
    case timestamp = "TIMESTAMP"
    case timestampSeconds = "TIMESTAMP_S"
    case timestampMilliseconds = "TIMESTAMP_MS"
    case timestampNanoseconds = "TIMESTAMP_NS"
    case timestampTz = "TIMESTAMPTZ"
    case timeTz = "TIMETZ"
    case bit = "BIT"
    case uuid = "UUID"
    case enumeration = "ENUM"
    case list = "LIST"
    case array = "ARRAY"
    case structure = "STRUCT"
    case map = "MAP"
    case union = "UNION"
    case bignum = "BIGNUM"
    case geometry = "GEOMETRY"

    var displayName: String { rawValue }
}

extension DuckDBLogicalType {
    static let typesTheValueAPICannotRender: Set<DuckDBLogicalType> = [
        .timestampSeconds,
        .timestampMilliseconds,
        .timestampNanoseconds,
        .timestampTz,
        .timeTz,
        .bit,
        .uuid,
        .enumeration,
        .list,
        .array,
        .structure,
        .map,
        .union,
        .bignum,
        .geometry,
    ]

    // The value API ends text at a NUL, so a result reads through data chunks when every column is one of these: text,
    // bytes, or a value with one spelling.
    static let typesReadFromChunks: Set<DuckDBLogicalType> = [
        .varchar, .blob, .boolean, .tinyint, .smallint, .integer, .bigint, .utinyint, .usmallint, .uinteger, .ubigint,
    ]

    var isReadFromChunks: Bool {
        Self.typesReadFromChunks.contains(self)
    }

    // DuckDB casts every other type to text, keeping its spelling without using the row value API.
    static func requiresTextProjection(_ type: DuckDBLogicalType?) -> Bool {
        guard let type else { return true }
        return !type.isReadFromChunks
    }

    static func requiresTextProjection(anyOf types: [DuckDBLogicalType?]) -> Bool {
        types.contains { requiresTextProjection($0) }
    }
}

enum DuckDBProjectedQuery {
    static func sourceAlias(at index: Int) -> String {
        "c\(index + 1)"
    }

    static func projection(for type: DuckDBLogicalType?, at index: Int, column: String) -> String {
        let source = sourceAlias(at: index)
        let alias = SQLQuoting.identifier(column)
        guard DuckDBLogicalType.requiresTextProjection(type) else {
            return "\(source) AS \(alias)"
        }
        let rendered = type == .geometry ? "ST_AsText(\(source))" : "CAST(\(source) AS VARCHAR)"
        return "CASE WHEN \(source) IS NULL THEN NULL ELSE \(rendered) END AS \(alias)"
    }

    static func build(function: String, columns: [(name: String, type: DuckDBLogicalType?)]) -> String {
        let projections = columns.enumerated()
            .map { projection(for: $0.element.type, at: $0.offset, column: $0.element.name) }
            .joined(separator: ", ")
        return "SELECT \(projections) FROM \(SQLQuoting.identifier(function))()"
    }
}
