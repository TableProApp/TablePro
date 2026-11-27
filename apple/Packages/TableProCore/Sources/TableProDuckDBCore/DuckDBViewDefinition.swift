import Foundation

public enum DuckDBViewDefinition {
    // DuckDB stores the `CREATE VIEW` the view was made with, which fails when run again, so a leading one becomes
    // `CREATE OR REPLACE VIEW`. Anything else comes back untouched.
    public static func makeReplaceable(_ sql: String) -> String {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sql }

        let prefix = "CREATE VIEW"
        guard trimmed.count >= prefix.count else { return sql }
        let head = String(trimmed.prefix(prefix.count))
        guard head.uppercased() == prefix else { return sql }

        return "CREATE OR REPLACE VIEW" + trimmed.dropFirst(prefix.count)
    }
}
