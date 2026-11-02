// Values written into a client's connection string or object pattern, by scalar like SQLQuoting.
// Inside the quotes every other scalar, a line break included, is data. NUL ends the C string the
// client reads, so it is refused rather than encoded.
public enum ConnectionStringQuoting {
    public struct NULRefusal: Error, Equatable, Sendable {
        public init() {}
    }

    // libpq conninfo: inside single quotes only `\` and `'` are special, each escaped with `\`.
    public static func libpqValue(_ value: String) throws -> String {
        try check(value)
        var quoted = String.UnicodeScalarView()
        quoted.append("'")
        for scalar in value.unicodeScalars {
            if scalar == "\\" || scalar == "'" { quoted.append("\\") }
            quoted.append(scalar)
        }
        quoted.append("'")
        return String(quoted)
    }

    // SqlClient: a double-quoted value may hold `;` and `=`, and a `"` inside it is doubled.
    public static func adoNetValue(_ value: String) throws -> String {
        try check(value)
        return SQLQuoting.identifier(value, quote: .doubleQuote)
    }

    // A psql `\d` pattern, as pg_dump `-t` reads it: each part double-quoted, so case, `.`, `*`, `?`
    // and `[` match literally.
    public static func psqlPattern(schema: String?, name: String) throws -> String {
        try check(name)
        let table = SQLQuoting.identifier(name)
        guard let schema else { return table }
        try check(schema)
        return SQLQuoting.identifier(schema) + "." + table
    }

    private static func check(_ value: String) throws {
        if value.unicodeScalars.contains("\0") { throw NULRefusal() }
    }
}
