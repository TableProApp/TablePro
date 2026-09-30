//
//  ParquetTypeMapper.swift
//  ParquetExportPlugin
//

import Foundation
import TableProPluginKit

/// Maps a source column's declared type to the DuckDB type the staging table uses.
///
/// Parquet is a typed format, so writing every column as a string would produce a file that reads
/// back with no numbers, no dates and no booleans. The source engine's own type name is the only
/// thing that says what a column holds, because a streamed value arrives as text either way.
public enum ParquetTypeMapper {
    /// The DuckDB type for a column, or `VARCHAR` when nothing better is known. A value that fails
    /// to cast becomes null rather than failing the export, which is what `TRY_CAST` gives.
    public static func duckDBType(forColumnType typeName: String, databaseTypeId: String) -> String {
        let base = baseName(typeName)
        if let moneyType = fixedPointMoneyTypes[databaseTypeId]?[base] { return moneyType }
        if integerTypes.contains(base) { return "BIGINT" }
        if exactNumericTypes.contains(base) {
            guard !enginesIgnoringDeclaredPrecision.contains(databaseTypeId) else { return "DOUBLE" }
            return exactNumericType(declaredAs: typeName)
        }
        if approximateNumericTypes.contains(base) { return "DOUBLE" }
        if booleanTypes.contains(base) { return "BOOLEAN" }
        if dateTypes.contains(base) { return "DATE" }
        if timestampTypes.contains(base) { return "TIMESTAMP" }
        if timeTypes.contains(base) { return "TIME" }
        if binaryTypes.contains(base) { return "BLOB" }
        return "VARCHAR"
    }

    /// A type name carries its width in parentheses (`VARCHAR(64)`, `NUMERIC(10,2)`) and sometimes a
    /// modifier after a space (`INT UNSIGNED`, `TIMESTAMP WITH TIME ZONE`). Only the first word
    /// before either matters here.
    public static func baseName(_ typeName: String) -> String {
        let trimmed = typeName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let withoutArgs = trimmed.split(separator: "(", maxSplits: 1).first.map(String.init) ?? trimmed
        return withoutArgs
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ")
            .first
            .map(String.init) ?? withoutArgs
    }

    private static func exactNumericType(declaredAs typeName: String) -> String {
        let arguments = typeArguments(typeName)
        guard let precision = arguments.first.flatMap({ Int($0) }),
              (1 ... maximumDecimalDigits).contains(precision) else { return "DOUBLE" }
        let scale = arguments.count > 1 ? Int(arguments[1]) : 0
        guard let scale, (0 ... precision).contains(scale) else { return "DOUBLE" }
        if scale == 0, precision <= maximumBigIntDigits { return "BIGINT" }
        return "DECIMAL(\(precision),\(scale))"
    }

    private static func typeArguments(_ typeName: String) -> [String] {
        guard let open = typeName.firstIndex(of: "("),
              let close = typeName[open...].firstIndex(of: ")") else { return [] }
        return typeName[typeName.index(after: open) ..< close]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static let maximumBigIntDigits = 18

    private static let maximumDecimalDigits = 38

    private static let enginesIgnoringDeclaredPrecision: Set<String> = [
        "SQLite", "libSQL", "Turso", "Cloudflare D1"
    ]

    private static let fixedPointMoneyTypes: [String: [String: String]] = [
        "SQL Server": ["money": "DECIMAL(19,4)", "smallmoney": "DECIMAL(10,4)"]
    ]

    private static let integerTypes: Set<String> = [
        "int", "int2", "int4", "int8", "integer", "smallint", "bigint", "tinyint",
        "mediumint", "serial", "bigserial", "smallserial", "year"
    ]

    private static let exactNumericTypes: Set<String> = ["decimal", "numeric", "number"]

    private static let approximateNumericTypes: Set<String> = [
        "float", "float4", "float8", "double", "real", "binary_float", "binary_double"
    ]

    private static let booleanTypes: Set<String> = ["bool", "boolean", "bit"]

    private static let dateTypes: Set<String> = ["date"]

    private static let timestampTypes: Set<String> = [
        "timestamp", "timestamptz", "datetime", "datetime2", "smalldatetime"
    ]

    private static let timeTypes: Set<String> = ["time", "timetz"]

    private static let binaryTypes: Set<String> = [
        "blob", "bytea", "binary", "varbinary", "longblob", "mediumblob", "tinyblob", "image", "raw"
    ]
}
