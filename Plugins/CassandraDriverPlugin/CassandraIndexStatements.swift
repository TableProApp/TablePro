//
//  CassandraIndexStatements.swift
//  CassandraDriverPlugin
//

import Foundation

/// Renders `CREATE INDEX` from `system_schema.indexes`.
///
/// Only a `COMPOSITES` or `KEYS` index is written. A `CUSTOM` index carries its implementation
/// class and an open-ended options map that this parser does not reproduce, so recreating one from
/// what the catalog reports would give a different index rather than the same one; those are left
/// out of the dump.
internal enum CassandraIndexStatements {
    /// The `target` an index is built on, read out of the options map Cassandra prints as
    /// `{target: col}`. A target naming a collection reads `keys(col)`, `values(col)`,
    /// `entries(col)` or `full(col)`.
    ///
    /// The surrounding quotes are stripped here and put back by `quotedTarget`, because a column
    /// name is a CQL identifier and every character except `"` is legal inside a quoted one. Left
    /// unquoted, a name holding `)` and `;` would end the statement and start another one in the
    /// dump the user then replays.
    internal static func target(fromOptions options: String) -> String? {
        guard let marker = options.range(of: "target:") else { return nil }
        let value = options[marker.upperBound...]
            .prefix { $0 != "," && $0 != "}" }
            .trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
        return value.isEmpty ? nil : value
    }

    /// The collection wrappers CQL accepts around an indexed column. Anything else in that position
    /// is a column name.
    private static let collectionWrappers = ["keys", "values", "entries", "full"]

    /// Quotes the target, keeping a collection wrapper as the keyword it is and quoting only the
    /// column inside it.
    internal static func quotedTarget(_ target: String, quote: (String) -> String) -> String {
        for wrapper in collectionWrappers {
            let prefix = wrapper + "("
            guard target.count > prefix.count + 1,
                  target.lowercased().hasPrefix(prefix),
                  target.hasSuffix(")") else { continue }
            let inner = String(target.dropFirst(prefix.count).dropLast())
            return "\(wrapper)(\(quote(inner)))"
        }
        return quote(target)
    }

    /// Each row is `index_name, kind, options`.
    internal static func render(
        rows: [[String?]],
        keyspace: String,
        table: String,
        quote: (String) -> String
    ) -> [String] {
        rows.compactMap { row -> String? in
            guard let name = row.element(at: 0) else { return nil }
            let kind = (row.element(at: 1) ?? "COMPOSITES").uppercased()
            guard kind == "COMPOSITES" || kind == "KEYS" else { return nil }
            guard let target = target(fromOptions: row.element(at: 2) ?? "") else { return nil }
            let column = quotedTarget(target, quote: quote)
            return "CREATE INDEX \(quote(name)) ON \(quote(keyspace)).\(quote(table)) (\(column));"
        }
    }
}

private extension Array where Element == String? {
    func element(at index: Int) -> String? {
        indices.contains(index) ? self[index] : nil
    }
}
