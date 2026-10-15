import Foundation

/// The statements that read a session's settings and put them back, spelled with backslash escapes like every
/// statement the plugin writes.
public enum MySQLSessionStatements {
    /// A system variable name the driver may interpolate into a statement: lowercase letters and underscores only.
    public static func isSettingName(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || $0 == "_" }
    }

    /// `SHOW` rather than `SELECT @@name`, because `SHOW` reports a boolean as `ON` or `OFF`, which `SET` takes back
    /// quoted; `SET SESSION foreign_key_checks = '1'` fails with 1231 (`scripts/probes/check-mysql-dump-session.sh`).
    /// A name that is not one is left out, and nil means nothing was left to ask about.
    public static func captureQuery(names: [String]) -> String? {
        let asked = names.filter(isSettingName)
        guard !asked.isEmpty else { return nil }
        let list = asked.map { "'\($0)'" }.joined(separator: ", ")
        return "SHOW SESSION VARIABLES WHERE Variable_name IN (\(list))"
    }

    /// What a `SHOW` row's value stands for. `SHOW` prints a NULL `character_set_results` as an empty string,
    /// measured on MariaDB 13.0.2, and no character set or collation is named by one, so there it means NULL.
    public static func reportedValue(name: String, value: String?) -> String? {
        guard let value, value.isEmpty else { return value }
        let namesCharset = name.hasPrefix("character_set_") || name.hasPrefix("collation_")
        return namesCharset ? nil : value
    }

    /// `SET SESSION <name> = <literal>`, with SQL `NULL` for a nil value, or nil for a name that is not one.
    public static func assignment(name: String, value: String?) -> String? {
        guard isSettingName(name) else { return nil }
        let literal = value.map { "'\(mysqlEscapeStringLiteral($0))'" } ?? "NULL"
        return "SET SESSION \(name) = \(literal)"
    }
}
