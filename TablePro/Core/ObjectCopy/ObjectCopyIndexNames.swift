//
//  ObjectCopyIndexNames.swift
//  TablePro
//
//  Index names that can stand side by side in the one schema a copy lands in.
//
//  MySQL, MariaDB, SQL Server and CockroachDB scope an index name to its table,
//  so every table of a shop can have its own `user_id` index. PostgreSQL,
//  SQLite, DuckDB and Oracle scope it to the schema, and the second
//  `CREATE INDEX "user_id"` was refused with `relation "user_id" already
//  exists`, stopping the copy part way through its tables.
//

import Foundation
import TableProPluginKit

internal enum ObjectCopyIndexNames {
    /// `tables` with every index the target creates renamed where its name would collide.
    ///
    /// An index from an engine that scopes names to the table takes its table's name as a prefix,
    /// PostgreSQL's own convention, unless it already names its table. Prefixing every one rather
    /// than only the colliding ones keeps the name from depending on which tables went in the same
    /// run, so a table copied tomorrow does not collide with one copied today. `taken` holds the
    /// names already in the target schema, folded to lower case, and gains each one given here.
    internal static func placed(
        _ tables: [TableStructureSnapshot],
        avoiding taken: inout Set<String>,
        from source: DatabaseType,
        to target: DatabaseType
    ) -> [TableStructureSnapshot] {
        guard source != target, sharesOneNamespace(target) else { return tables }
        let prefixes = !sharesOneNamespace(source)
        let style = NewTableNameStyle.forDatabaseType(target)
        taken.formUnion(NewTableNaming.comparisonKeys(for: tables.map(\.name)))

        return tables.map { table in
            let indexes = table.indexes.map { index -> EditableIndexDefinition in
                guard !index.isPrimary else { return index }
                let wanted = prefixes && !names(index.name, table: table.name)
                    ? "\(table.name)_\(index.name)"
                    : index.name
                let fitted = NewTableNaming.truncating(wanted, toByteLength: style.maximumByteLength)
                let name = NewTableNaming.disambiguating(
                    fitted.isEmpty ? wanted : fitted, style: style, avoiding: taken
                )
                taken.insert(name.lowercased())
                var renamed = index
                renamed.name = name
                return renamed
            }
            guard indexes != table.indexes else { return table }
            return TableStructureSnapshot(
                name: table.name,
                schema: table.schema,
                columns: table.columns,
                indexes: indexes,
                foreignKeys: table.foreignKeys,
                engine: table.engine,
                charset: table.charset,
                collation: table.collation
            )
        }
    }

    /// Whether `type` keeps one namespace of index names per schema, shared by all its tables.
    ///
    /// Measured by `scripts/probes/check-index-name-scope.sh` for PostgreSQL, SQLite and DuckDB.
    /// Oracle documents indexes as schema objects in a namespace of their own. CockroachDB
    /// documents an index name as unique to its table, despite sharing PostgreSQL's types. An engine
    /// not named here keeps its source names, as every copy did before.
    internal static func sharesOneNamespace(_ type: DatabaseType) -> Bool {
        switch SQLTypeFamily.of(type) {
        case .postgres:
            return type != .cockroachdb
        case .sqlite, .duckdb, .oracle:
            return true
        default:
            return false
        }
    }

    /// `idx_orders_created_at` already says which table it indexes; `user_id` does not.
    private static func names(_ index: String, table: String) -> Bool {
        let index = index.lowercased()
        let table = table.lowercased()
        return index.hasPrefix(table + "_")
            || index.hasSuffix("_" + table)
            || index.contains("_" + table + "_")
    }
}
