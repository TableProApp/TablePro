//
//  DuckDBTypeRendering.swift
//  DuckDBDriverPlugin
//

import Foundation

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

    var isRenderedByValueAPI: Bool {
        !Self.typesTheValueAPICannotRender.contains(self)
    }

    static func requiresTextProjection(_ type: DuckDBLogicalType?) -> Bool {
        guard let type else { return true }
        return !type.isRenderedByValueAPI
    }

    static func requiresTextProjection(anyOf types: [DuckDBLogicalType?]) -> Bool {
        types.contains { requiresTextProjection($0) }
    }
}

enum DuckDBProjectedQuery {
    static let subqueryAlias = "_tp_cast"

    static func sourceAlias(at index: Int) -> String {
        "c\(index + 1)"
    }

    static func quoteIdentifier(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    static func projection(for type: DuckDBLogicalType?, at index: Int, column: String) -> String {
        let source = sourceAlias(at: index)
        let alias = quoteIdentifier(column)
        guard DuckDBLogicalType.requiresTextProjection(type) else {
            return "\(source) AS \(alias)"
        }
        let rendered = type == .geometry ? "ST_AsText(\(source))" : "CAST(\(source) AS VARCHAR)"
        return "CASE WHEN \(source) IS NULL THEN NULL ELSE \(rendered) END AS \(alias)"
    }

    static func build(originalQuery: String, columns: [(name: String, type: DuckDBLogicalType?)]) -> String? {
        guard !columns.isEmpty else { return nil }
        var inner = originalQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if inner.hasSuffix(";") {
            inner = String(inner.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !inner.isEmpty else { return nil }
        let projections = columns.enumerated()
            .map { projection(for: $0.element.type, at: $0.offset, column: $0.element.name) }
            .joined(separator: ", ")
        let aliases = columns.indices.map(sourceAlias(at:)).joined(separator: ", ")
        return "SELECT \(projections) FROM (\(inner)\n) AS \(subqueryAlias)(\(aliases))"
    }
}
