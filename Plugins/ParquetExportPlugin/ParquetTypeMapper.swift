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
///
/// The mapping is deliberately coarse. Getting a width or a precision wrong writes a file that
/// silently truncates, and Parquet's own type set is small: matching families is right, matching
/// exact declarations is not achievable across twenty engines.
public enum ParquetTypeMapper {
    /// The DuckDB type for a column, or `VARCHAR` when nothing better is known. A value that fails
    /// to cast becomes null rather than failing the export, which is what `TRY_CAST` gives.
    public static func duckDBType(forColumnType typeName: String) -> String {
        let base = baseName(typeName)
        if integerTypes.contains(base) { return "BIGINT" }
        if decimalTypes.contains(base) { return "DOUBLE" }
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

    private static let integerTypes: Set<String> = [
        "int", "int2", "int4", "int8", "integer", "smallint", "bigint", "tinyint",
        "mediumint", "serial", "bigserial", "smallserial", "year", "number"
    ]

    private static let decimalTypes: Set<String> = [
        "decimal", "numeric", "float", "float4", "float8", "double", "real", "money"
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
