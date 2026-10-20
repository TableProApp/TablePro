import Foundation

public extension ColumnInfo {
    // Sent '', a typed column stores its zero value (lax MySQL, SQL Server) or refuses the write; an unknown name such as USER-DEFINED keeps ''.
    var holdsEmptyString: Bool {
        Self.holdsEmptyString(typeName: typeName)
    }

    static func holdsEmptyString(typeName: String) -> Bool {
        let upper = unwrapped(typeName.uppercased())
        if upper.hasSuffix("[]") || upper.hasPrefix("ARRAY") { return false }
        let base = upper.prefix { $0 != "(" }.trimmingCharacters(in: .whitespaces)
        if base == "ENUM" { return ["('',", ",'',", ",'')", "('')"].contains { upper.contains($0) } }
        if base.hasPrefix("BIT VARYING") { return true }
        return !typedStems.contains(stem(of: base))
    }

    // Matched on the first word with width digits dropped, so INT4, Int64, DATETIME2 and FLOAT8 read as their family.
    private static let typedStems: Set<String> = [
        "DATE", "TIME", "TIMETZ", "TIMESTAMP", "TIMESTAMPTZ", "TIMESTAMP_S", "TIMESTAMP_MS", "TIMESTAMP_NS",
        "TIMESTAMP_TZ", "DATETIME", "DATETIMEOFFSET", "SMALLDATETIME", "YEAR", "INTERVAL",
        "INT", "UINT", "INTEGER", "UINTEGER", "TINYINT", "UTINYINT", "SMALLINT", "USMALLINT", "MEDIUMINT",
        "BIGINT", "UBIGINT", "HUGEINT", "UHUGEINT", "SERIAL", "SMALLSERIAL", "BIGSERIAL",
        "DECIMAL", "DEC", "NUMERIC", "NUMBER", "FLOAT", "DOUBLE", "REAL", "MONEY", "SMALLMONEY",
        "BINARY_FLOAT", "BINARY_DOUBLE", "BIT", "BOOL", "BOOLEAN", "JSON", "JSONB",
        "UUID", "UNIQUEIDENTIFIER", "INET", "CIDR", "MACADDR",
        "GEOMETRY", "GEOGRAPHY", "POINT", "LINESTRING", "POLYGON", "MULTIPOINT", "MULTILINESTRING",
        "MULTIPOLYGON", "GEOMETRYCOLLECTION"
    ]

    internal static func stem(of base: String) -> String {
        var word = String(base.prefix { $0 != " " })
        while word.count > 1, word.last?.isNumber == true {
            word.removeLast()
        }
        return word
    }

    internal static func unwrapped(_ typeName: String) -> String {
        var name = typeName.trimmingCharacters(in: .whitespaces)
        while let wrapper = ["NULLABLE(", "LOWCARDINALITY("].first(where: { name.hasPrefix($0) }), name.hasSuffix(")") {
            name = String(name.dropFirst(wrapper.count).dropLast())
        }
        return name
    }
}
