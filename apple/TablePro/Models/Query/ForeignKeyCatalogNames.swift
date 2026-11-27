//
//  ForeignKeyCatalogNames.swift
//  TablePro
//

import Foundation

// SQLite reports a key's target as its REFERENCES clause spells it: `parent(id)` for the table `Parent`.
internal enum ForeignKeyCatalogNames {
    internal static func canonicalized(
        _ foreignKeys: [CatalogName: [ForeignKeyInfo]],
        columns: [CatalogName: [String]]
    ) -> [CatalogName: [ForeignKeyInfo]] {
        let tables = Lookup(columns.keys.map(\.text))
        var columnLookups: [CatalogName: Lookup] = [:]
        func columnLookup(_ table: CatalogName) -> Lookup {
            if let cached = columnLookups[table] { return cached }
            let lookup = Lookup(columns[table] ?? [])
            columnLookups[table] = lookup
            return lookup
        }

        var result: [CatalogName: [ForeignKeyInfo]] = [:]
        for (childTable, keys) in foreignKeys {
            result[childTable] = keys.map { key in
                guard let parent = tables.canonical(key.referencedTable) else { return key }
                let column = columnLookup(childTable).canonical(key.column) ?? key.column
                let referencedColumn = columnLookup(CatalogName(parent)).canonical(key.referencedColumn)
                    ?? key.referencedColumn
                guard !CatalogName.same(parent, key.referencedTable) || column != key.column
                    || referencedColumn != key.referencedColumn
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

    // A name found as written wins; otherwise the one name it matches ignoring case, never one of two.
    private struct Lookup {
        private let exact: Set<CatalogName>
        private let folded: [String: Set<CatalogName>]

        init(_ names: some Sequence<String>) {
            var exact: Set<CatalogName> = []
            var folded: [String: Set<CatalogName>] = [:]
            for name in names {
                exact.insert(CatalogName(name))
                folded[name.lowercased(), default: []].insert(CatalogName(name))
            }
            self.exact = exact
            self.folded = folded
        }

        func canonical(_ name: String) -> String? {
            if exact.contains(CatalogName(name)) { return name }
            guard let matches = folded[name.lowercased()], matches.count == 1 else { return nil }
            return matches.first?.text
        }
    }
}
