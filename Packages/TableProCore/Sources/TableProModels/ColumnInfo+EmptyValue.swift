import Foundation

public extension ColumnInfo {
    /// Whether `''` is a value of this column's type, read from the declared type name alone.
    ///
    /// A date, number, boolean, JSON, UUID or geometry has no empty value: sent `''`, MySQL without
    /// strict mode stores its zero value (`0000-00-00 00:00:00`, `0`), SQL Server stores
    /// `1900-01-01` or `0`, and a strict MySQL or PostgreSQL refuses the write. Every other name,
    /// including one this does not know, such as PostgreSQL's `USER-DEFINED` for a `citext` or a
    /// domain, keeps `''`.
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

    /// Type names by their first word with any width digits dropped, so `INT4`, `Int64`,
    /// `DATETIME2`, `DateTime64` and `FLOAT8` read as their family.
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

    private static func stem(of base: String) -> String {
        var word = String(base.prefix { $0 != " " })
        while word.count > 1, word.last?.isNumber == true {
            word.removeLast()
        }
        return word
    }

    private static func unwrapped(_ typeName: String) -> String {
        var name = typeName.trimmingCharacters(in: .whitespaces)
        while let wrapper = ["NULLABLE(", "LOWCARDINALITY("].first(where: { name.hasPrefix($0) }), name.hasSuffix(")") {
            name = String(name.dropFirst(wrapper.count).dropLast())
        }
        return name
    }
}
