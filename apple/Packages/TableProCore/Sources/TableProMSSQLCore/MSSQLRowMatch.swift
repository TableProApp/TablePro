import Foundation

// Text is sent as nvarchar, and a char or varchar column read against it compares by Unicode rules even under a SQL
// collation, where `ß` equals `ss`. The column's own rules keep `Weßels` and `Wessels` apart, so a unique key can hold
// both and `=` alone matched both rows. Comparing the stored text by code point keeps the one row the value was read
// from, with trailing spaces padded as `=` pads them (measured on SQL Server 2022). Every character type gets it, since
// a result can read a varchar column through a cast to nvarchar.
public enum MSSQLRowMatch {
    private static let characterTypes: Set<String> = ["char", "varchar", "text", "nchar", "nvarchar", "ntext", "sysname"]

    public static func comparesText(typeName: String?) -> Bool {
        guard let typeName else { return false }
        let base = typeName.lowercased().prefix { $0 != "(" }.trimmingCharacters(in: .whitespaces)
        return characterTypes.contains(base)
    }

    // `value` is the placeholder or literal the row match already compares the column with.
    public static func exactText(_ quotedColumn: String, equals value: String) -> String {
        "CAST(\(quotedColumn) AS NVARCHAR(MAX)) COLLATE Latin1_General_100_BIN2 = \(value)"
    }
}
