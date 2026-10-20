import Foundation

public extension ColumnInfo {
    var isJSONType: Bool {
        Self.isJSONType(typeName: typeName)
    }

    var isNumericType: Bool {
        Self.isNumericType(typeName: typeName)
    }

    var mayHoldJSONText: Bool {
        Self.mayHoldJSONText(typeName: typeName)
    }

    static func isJSONType(typeName: String) -> Bool {
        guard let stem = scalarStem(of: typeName) else { return false }
        return stem == "JSON" || stem == "JSONB"
    }

    static func isNumericType(typeName: String) -> Bool {
        guard let stem = scalarStem(of: typeName) else { return false }
        return numericStems.contains(stem)
    }

    // DuckDB prints a list, struct or map as text that can parse as JSON, and PostgreSQL types an array result unknown.
    static func mayHoldJSONText(typeName: String) -> Bool {
        guard holdsEmptyString(typeName: typeName), let stem = scalarStem(of: typeName) else { return false }
        return !nestedStems.contains(stem)
    }

    private static let numericStems: Set<String> = [
        "INT", "UINT", "INTEGER", "UINTEGER", "TINYINT", "UTINYINT", "SMALLINT", "USMALLINT", "MEDIUMINT",
        "BIGINT", "UBIGINT", "HUGEINT", "UHUGEINT", "SERIAL", "SMALLSERIAL", "BIGSERIAL",
        "DECIMAL", "DEC", "NUMERIC", "NUMBER", "FLOAT", "DOUBLE", "REAL", "MONEY", "SMALLMONEY",
        "BINARY_FLOAT", "BINARY_DOUBLE"
    ]

    private static let nestedStems: Set<String> = ["UNKNOWN", "LIST", "STRUCT", "MAP"]

    private static func scalarStem(of typeName: String) -> String? {
        let upper = unwrapped(typeName.uppercased())
        if upper.hasSuffix("[]") || upper.hasPrefix("ARRAY") { return nil }
        return stem(of: upper.prefix { $0 != "(" }.trimmingCharacters(in: .whitespaces))
    }
}
