import Foundation
import TableProModels
import TableProPluginKit

// Unknown types fall to `.text`: `int_col = '5'` still matches everywhere, `text_col = 02134` finds the wrong row.
nonisolated public enum FilterColumnKind {
    public static func kind(forTypeName typeName: String) -> PluginColumnKind {
        let base = typeName.lowercased().prefix { $0 != "(" }
        let words = base.split(whereSeparator: \.isWhitespace).filter { $0 != "unsigned" }
        // PostgreSQL's `bit varying` is a bit string, and `= 101` has no operator there.
        guard let first = words.first.map(String.init), !words.contains("varying") else { return .text }
        if integerNames.contains(first) { return .integer }
        if decimalNames.contains(first) { return .decimal }
        return .text
    }

    public static func column(named name: String, in columns: [ColumnInfo]) -> ColumnInfo? {
        if let exact = columns.first(where: { $0.name == name }) { return exact }
        let folded = columns.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        return folded.count == 1 ? folded.first : nil
    }

    // A SQLite column with no affinity (typeless, any BLOB, ANY in a STRICT table) does not match a
    // stored 5 to `= '5'`: keep the untyped rule there.
    public static func kind(of column: ColumnInfo?) -> PluginColumnKind? {
        guard let column else { return nil }
        let typeName = column.typeName.trimmingCharacters(in: .whitespaces).lowercased()
        guard !typeName.isEmpty, !typeName.contains("blob"), typeName != "any" else { return nil }
        return kind(forTypeName: typeName)
    }

    private static let integerNames: Set<String> = [
        "int", "integer", "tinyint", "smallint", "mediumint", "bigint",
        "int1", "int2", "int3", "int4", "int8",
        "serial", "smallserial", "bigserial",
        "hugeint", "uhugeint", "utinyint", "usmallint", "uinteger", "ubigint",
        "bit", "bool", "boolean"
    ]

    private static let decimalNames: Set<String> = [
        "decimal", "numeric", "number", "real", "float", "double",
        "float4", "float8", "binary_float", "binary_double"
    ]
}
