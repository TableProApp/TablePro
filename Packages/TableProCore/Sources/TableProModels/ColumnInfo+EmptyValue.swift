import Foundation

public extension ColumnInfo {
    /// Whether `''` is a value of this column's type, read from the declared type name alone.
    ///
    /// Only character, binary and SET types hold the empty string. A date, number, boolean, JSON,
    /// UUID or geometry has no empty value: sent `''`, MySQL without strict mode stores its zero
    /// value (`0000-00-00 00:00:00`, `0`), SQL Server stores `1900-01-01` or `0`, and a strict
    /// MySQL or PostgreSQL refuses the write. A column with no declared type keeps `''`, as SQLite
    /// does for an expression.
    var holdsEmptyString: Bool {
        Self.holdsEmptyString(typeName: typeName)
    }

    static func holdsEmptyString(typeName: String) -> Bool {
        let upper = unwrapped(typeName.uppercased())
        guard !upper.isEmpty else { return true }
        if upper.hasSuffix("[]") || upper.hasPrefix("ARRAY") { return false }
        let base = upper.prefix { $0 != "(" }.trimmingCharacters(in: .whitespaces)
        if base == "ENUM" { return upper.contains("('',") || upper.contains(",'')") || upper.contains("('')") }
        if base == "SET" { return true }
        if numericNames.contains(base) { return false }
        return characterMarkers.contains { base.contains($0) } || characterNames.contains(base)
    }

    /// Oracle's floating point types, whose names carry `BINARY`.
    private static let numericNames: Set<String> = ["BINARY_FLOAT", "BINARY_DOUBLE"]

    /// The same words SQLite reads a declared type's text and blob affinity from, plus the binary
    /// spellings of the other engines.
    private static let characterMarkers = ["CHAR", "TEXT", "CLOB", "BLOB", "BINARY", "BYTEA"]

    private static let characterNames: Set<String> = ["STRING", "FIXEDSTRING", "NAME", "XML", "RAW", "IMAGE", "BYTES"]

    private static func unwrapped(_ typeName: String) -> String {
        var name = typeName.trimmingCharacters(in: .whitespaces)
        while let wrapper = ["NULLABLE(", "LOWCARDINALITY("].first(where: { name.hasPrefix($0) }), name.hasSuffix(")") {
            name = String(name.dropFirst(wrapper.count).dropLast())
        }
        return name
    }
}
