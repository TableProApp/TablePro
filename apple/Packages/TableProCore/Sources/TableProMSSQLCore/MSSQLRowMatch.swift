import Foundation

// Text is sent as nvarchar, and a char or varchar column read against it compares by Unicode rules even under a SQL
// collation, where `ß` equals `ss`. The column's own rules keep `Weßels` and `Wessels` apart, so a unique key can hold
// both and `=` alone matched both rows. Comparing the stored text by code point keeps the one row the value was read
// from, with trailing spaces padded as `=` pads them (measured on SQL Server 2022).
public enum MSSQLRowMatch {
    public static func comparesNarrowText(typeName: String?) -> Bool {
        guard let typeName else { return false }
        let base = typeName.lowercased().prefix { $0 != "(" }.trimmingCharacters(in: .whitespaces)
        return base == "char" || base == "varchar" || base == "text"
    }

    // `value` is the placeholder or literal the row match already compares the column with.
    public static func exactText(_ quotedColumn: String, equals value: String) -> String {
        "CAST(\(quotedColumn) AS NVARCHAR(MAX)) COLLATE Latin1_General_100_BIN2 = \(value)"
    }

    // A foreign key finds its parent by the column's own rules, where `weßels` equals `Weßels` but not `Wessels`, so
    // the value is compared as varchar. It reaches varchar through the database's code page; when that loses a
    // character, the Unicode comparison stands in rather than one against the `?` it became.
    public static func columnRules(_ quotedColumn: String, equals literal: String) -> String {
        let narrow = "CAST(\(literal) AS VARCHAR(MAX))"
        let lossless = "CAST(\(narrow) AS NVARCHAR(MAX)) COLLATE Latin1_General_100_BIN2 = \(literal)"
        return "((\(quotedColumn) = \(narrow) AND \(lossless)) OR (\(quotedColumn) = \(literal) AND NOT \(lossless)))"
    }
}
