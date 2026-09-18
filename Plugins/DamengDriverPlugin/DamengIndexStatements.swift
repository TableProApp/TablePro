//
//  DamengIndexStatements.swift
//  DamengDriverPlugin
//

import Foundation

/// Renders `CREATE INDEX` from Dameng's `ALL_INDEXES` catalog, which follows Oracle's shape.
///
/// A `PRIMARY KEY` or `UNIQUE` constraint carries its own index inside `CREATE TABLE`, so the
/// query behind this excludes those and only what a dump has to recreate reaches here.
internal enum DamengIndexStatements {
    /// Each row is `INDEX_NAME, UNIQUENESS, COLUMN_NAME`. Statements come back in the order the
    /// rows arrive, one per index.
    internal static func render(
        rows: [[String?]],
        schema: String,
        table: String,
        quote: (String) -> String
    ) -> [String] {
        var order: [String] = []
        var columns: [String: [String]] = [:]
        var unique: [String: Bool] = [:]

        for row in rows {
            guard let name = row.element(at: 0), let column = row.element(at: 2) else { continue }
            if columns[name] == nil {
                order.append(name)
                columns[name] = []
                unique[name] = row.element(at: 1)?.uppercased() == "UNIQUE"
            }
            columns[name]?.append(quote(column))
        }

        return order.compactMap { name in
            guard let keyColumns = columns[name], !keyColumns.isEmpty else { return nil }
            let uniqueClause = unique[name] == true ? "UNIQUE " : ""
            return "CREATE \(uniqueClause)INDEX \(quote(schema)).\(quote(name))"
                + " ON \(quote(schema)).\(quote(table))"
                + " (\(keyColumns.joined(separator: ", ")));"
        }
    }
}

private extension Array where Element == String? {
    func element(at index: Int) -> String? {
        indices.contains(index) ? self[index] : nil
    }
}
