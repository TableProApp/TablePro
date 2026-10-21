//
//  ForeignKeyCatalogNames.swift
//  TablePro
//

import Foundation

// SQLite reports a key's target as its REFERENCES clause spells it: `parent(id)` for the table `Parent`.
internal enum ForeignKeyCatalogNames {
    internal static func canonicalized(
        _ foreignKeys: [String: [ForeignKeyInfo]],
        columns: [String: [String]]
    ) -> [String: [ForeignKeyInfo]] {
        let tables = Lookup(columns.keys)
        var columnLookups: [String: Lookup] = [:]
        func columnLookup(_ table: String) -> Lookup {
            if let cached = columnLookups[table] { return cached }
            let lookup = Lookup(columns[table] ?? [])
            columnLookups[table] = lookup
            return lookup
        }

        var result: [String: [ForeignKeyInfo]] = [:]
        for (childTable, keys) in foreignKeys {
            result[childTable] = keys.map { key in
                guard let parent = tables.canonical(key.referencedTable) else { return key }
                let column = columnLookup(childTable).canonical(key.column) ?? key.column
                let referencedColumn = columnLookup(parent).canonical(key.referencedColumn) ?? key.referencedColumn
                guard parent != key.referencedTable || column != key.column || referencedColumn != key.referencedColumn
                else { return key }
                return ForeignKeyInfo(
                    name: key.name,
                    column: column,
                    referencedTable: parent,
                    referencedColumn: referencedColumn,
                    referencedDatabase: key.referencedDatabase,
                    referencedSchema: key.referencedSchema,
                    onDelete: key.onDelete,
                    onUpdate: key.onUpdate
                )
            }
        }
        return result
    }

    private struct Lookup {
        private let exact: Set<String>
        private let folded: [String: [String]]

        init(_ names: some Sequence<String>) {
            var exact: Set<String> = []
            var folded: [String: [String]] = [:]
            for name in names {
                exact.insert(name)
                folded[name.lowercased(), default: []].append(name)
            }
            self.exact = exact
            self.folded = folded
        }

        func canonical(_ name: String) -> String? {
            if exact.contains(name) { return name }
            guard let matches = folded[name.lowercased()], matches.count == 1 else { return nil }
            return matches[0]
        }
    }
}
