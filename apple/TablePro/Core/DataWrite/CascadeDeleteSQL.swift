import Foundation

struct CascadeSQLDialect: Sendable {
    let quote: @Sendable (String) -> String
    let qualifiedTable: @Sendable (String) -> String
    let textLiteral: @Sendable (String) -> String
}

enum CascadeDeleteSQL {
    // Oracle refuses an IN list longer than this (ORA-01795).
    static let inListLimit = 1_000

    // Written against the table's bare name, so the same text filters a tab opened on that table.
    static func condition(
        for effect: CascadeEffect,
        excluding exclusions: [CascadeRowSet] = [],
        dialect: CascadeSQLDialect
    ) -> String? {
        guard effect.isCountable else { return nil }
        let outer = dialect.quote(effect.table)
        let tables = (effect.paths + exclusions).reduce(into: Set([effect.table])) { $0.formUnion($1.tables) }
        let renderer = Renderer(dialect: dialect, aliasPrefix: aliasPrefix(avoiding: tables))
        let condition = union(effect.paths.map { renderer.predicate($0, on: outer, depth: 1) })
        let excluded = exclusions.filter { $0.table == effect.table }.map { renderer.predicate($0, on: outer, depth: 1) }
        guard !excluded.isEmpty else { return condition }
        // NOT over an IN that meets a NULL is NULL and would drop the row, so the test is spelled as a CASE.
        return "(\(condition)) AND CASE WHEN \(union(excluded)) THEN 1 ELSE 0 END = 0"
    }

    private static func union(_ predicates: [String]) -> String {
        predicates.count == 1 ? predicates[0] : predicates.map { "(\($0))" }.joined(separator: " OR ")
    }

    static func countQuery(table: String, condition: String, dialect: CascadeSQLDialect) -> String {
        "SELECT COUNT(*) FROM \(dialect.qualifiedTable(table)) WHERE \(condition)"
    }

    // An alias equal to a table name in the query would capture references meant for that table.
    static func aliasPrefix(avoiding tables: Set<String>) -> String {
        let lowered = tables.map { $0.lowercased() }
        var prefix = "cascade_"
        while lowered.contains(where: { $0.hasPrefix(prefix) }) {
            prefix = "x" + prefix
        }
        return prefix
    }

    private struct Renderer {
        let dialect: CascadeSQLDialect
        let aliasPrefix: String

        func predicate(_ rows: CascadeRowSet, on qualifier: String, depth: Int) -> String {
            switch rows {
            case .keyed(_, let columns, let values):
                return keyed(columns: columns, values: values, on: qualifier)
            case .referencing(_, let columns, let parentColumns, let parent):
                let alias = "\(aliasPrefix)\(depth)"
                let parentTable = dialect.qualifiedTable(parent.table)
                let inner = predicate(parent, on: alias, depth: depth + 1)
                // The parent column goes on the left: SQLite compares a key with the parent's collation and
                // affinity, and an `=` takes them from its left operand. A correlated EXISTS also needs no
                // row value IN, which SQL Server lacks, and is never NULL.
                let joins = zip(columns, parentColumns).map { column, parentColumn in
                    "\(alias).\(dialect.quote(parentColumn)) = \(qualifier).\(dialect.quote(column))"
                }
                return "EXISTS (SELECT 1 FROM \(parentTable) \(alias) WHERE "
                    + joins.joined(separator: " AND ") + " AND (\(inner)))"
            }
        }

        private func keyed(columns: [String], values: [[String]], on qualifier: String) -> String {
            guard !values.isEmpty else { return "1 = 0" }
            if columns.count == 1, let column = columns.first {
                let target = "\(qualifier).\(dialect.quote(column))"
                let lists = stride(from: 0, to: values.count, by: CascadeDeleteSQL.inListLimit).map { start in
                    let chunk = values[start..<min(start + CascadeDeleteSQL.inListLimit, values.count)]
                    return "\(target) IN (" + chunk.compactMap(\.first).map(dialect.textLiteral).joined(separator: ", ") + ")"
                }
                return lists.count == 1 ? lists[0] : lists.map { "(\($0))" }.joined(separator: " OR ")
            }
            return values.map { tuple in
                "(" + zip(columns, tuple).map { column, value in
                    "\(qualifier).\(dialect.quote(column)) = \(dialect.textLiteral(value))"
                }.joined(separator: " AND ") + ")"
            }.joined(separator: " OR ")
        }
    }
}
