//
//  DuckDBViewDefinition.swift
//  DuckDBDriverPlugin
//
//  Turns DuckDB's stored view SQL into something the user can run back.
//

import Foundation

enum DuckDBViewDefinition {
    /// DuckDB stores a view as the `CREATE VIEW ...` it was made with. TablePro opens that
    /// text in a query tab for editing, and running it again fails because the view already
    /// exists, so the statement is promoted to `CREATE OR REPLACE VIEW`.
    ///
    /// Only a leading `CREATE VIEW` is rewritten, and only when the stored SQL does not
    /// already say `OR REPLACE`. Anything else is returned untouched rather than guessed at.
    static func makeReplaceable(_ sql: String) -> String {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sql }

        let prefix = "CREATE VIEW"
        guard trimmed.count >= prefix.count else { return sql }
        let head = String(trimmed.prefix(prefix.count))
        guard head.uppercased() == prefix else { return sql }

        return "CREATE OR REPLACE VIEW" + trimmed.dropFirst(prefix.count)
    }
}
