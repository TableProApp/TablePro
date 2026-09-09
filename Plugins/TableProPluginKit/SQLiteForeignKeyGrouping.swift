//
//  SQLiteForeignKeyGrouping.swift
//  TableProPluginKit
//

import Foundation

/// Turns SQLite's `PRAGMA foreign_key_list` rows into the foreign keys a schema editor can show.
///
/// The pragma reports the columns and the actions and nothing else. It does not report the
/// constraint's name, so a key declared `CONSTRAINT fk_orders_customer …` reads back anonymous and
/// the name the user typed is lost the next time the table is read. And measured on 3.54, it
/// reports the parent column as null for `REFERENCES parent` written without a column list, even
/// when the parent has a primary key.
///
/// So three sources are used: the pragma for the columns and actions, the stored `CREATE TABLE`
/// text for the name, and the parent's own primary key for what the shorthand left out. The pragma
/// and the DDL are matched on the relationship each describes rather than on position, because the
/// pragma numbers keys in reverse declaration order and renumbers them whenever one is added or
/// dropped.
public enum SQLiteForeignKeyGrouping {
    /// One key as the pragma describes it, before names are attached.
    private struct Group {
        let id: String
        var columns: [String] = []
        var referencedColumns: [String] = []
        var referencedTable = ""
        var onUpdate = "NO ACTION"
        var onDelete = "NO ACTION"
    }

    /// The foreign keys of `table`.
    ///
    /// `pragmaRows` are `PRAGMA foreign_key_list` rows, `id | seq | table | from | to | on_update |
    /// on_delete | match`. `createTableSQL` is the statement `sqlite_master` stores, or nil where it
    /// could not be read, in which case every key falls back to a positional name as before.
    ///
    /// A key spanning several columns comes back as one `PluginForeignKeyInfo` per column pair, all
    /// sharing one name, which is how the schema editor regroups them into a single composite key.
    public static func infos(
        table: String,
        pragmaRows: [[PluginCellValue]],
        createTableSQL: String?,
        primaryKeysByTable: [String: [String]] = [:]
    ) -> [PluginForeignKeyInfo] {
        let groups = groups(from: pragmaRows, primaryKeysByTable: primaryKeysByTable)
        let names = resolvedNames(for: groups, table: table, createTableSQL: createTableSQL)

        return groups.enumerated().flatMap { offset, group -> [PluginForeignKeyInfo] in
            let name = names[offset]
            return zip(group.columns, group.referencedColumns).map { column, referencedColumn in
                PluginForeignKeyInfo(
                    name: name,
                    column: column,
                    referencedTable: group.referencedTable,
                    referencedColumn: referencedColumn,
                    onDelete: group.onDelete,
                    onUpdate: group.onUpdate
                )
            }
        }
    }

    private static func groups(
        from rows: [[PluginCellValue]],
        primaryKeysByTable: [String: [String]]
    ) -> [Group] {
        var groups: [Group] = []
        var indexByID: [String: Int] = [:]

        for row in rows {
            guard row.count >= 5,
                  let referencedTable = row[safe: 2]?.asText,
                  let column = row[safe: 3]?.asText else { continue }
            let id = row[safe: 0]?.asText ?? "0"

            let index: Int
            if let existing = indexByID[id] {
                index = existing
            } else {
                index = groups.count
                indexByID[id] = index
                groups.append(Group(id: id))
            }

            groups[index].referencedTable = referencedTable
            groups[index].columns.append(column)
            /// Measured: `REFERENCES parent` with no column list reports null here even when the
            /// parent has a primary key, so the parent's own key is what fills it. Falling back to
            /// the child's column name instead would show the wrong target and stop the key being
            /// matched for removal.
            let parentKey = primaryKeysByTable[referencedTable.lowercased()] ?? []
            let position = groups[index].columns.count - 1
            groups[index].referencedColumns.append(
                row[safe: 4]?.asText ?? parentKey[safe: position] ?? column
            )
            if let onUpdate = row[safe: 5]?.asText { groups[index].onUpdate = onUpdate }
            if let onDelete = row[safe: 6]?.asText { groups[index].onDelete = onDelete }
        }
        return groups
    }

    /// The name each group is shown and addressed by.
    ///
    /// The `CONSTRAINT` name from the DDL where there is one and it is unambiguous, and the
    /// positional `fk_<table>_<id>` otherwise. SQLite lets two constraints share a name, and the
    /// schema editor groups its rows by name, so a recovered name that collides would merge two
    /// unrelated keys into one composite relationship. A collision falls back to the positional
    /// name, which is unique by construction.
    private static func resolvedNames(
        for groups: [Group],
        table: String,
        createTableSQL: String?
    ) -> [String] {
        let declared = declaredNames(for: groups, createTableSQL: createTableSQL)
        var occurrences: [String: Int] = [:]
        for name in declared.compactMap({ $0 }) {
            occurrences[name, default: 0] += 1
        }
        return groups.enumerated().map { offset, group in
            guard let name = declared[offset], occurrences[name] == 1 else {
                return "fk_\(table)_\(group.id)"
            }
            return name
        }
    }

    /// The `CONSTRAINT` name the DDL gave each group, where it gave one.
    ///
    /// Matched on the child columns, the parent table, and the parent columns when the DDL supplies
    /// them. The parent columns are compared only then: the DDL may omit them and the pragma always
    /// reports something, so requiring them to agree everywhere would fail the shorter form. Two
    /// keys from the same column to different columns of the same parent are legal, and ignoring
    /// the parent columns entirely swapped their names.
    private static func declaredNames(for groups: [Group], createTableSQL: String?) -> [String?] {
        guard let createTableSQL,
              let parsed = SQLiteTableDDL.parse(createTableSQL: createTableSQL) else {
            return Array(repeating: nil, count: groups.count)
        }
        var clauses = SQLiteTableDDL.foreignKeys(in: parsed)

        return groups.map { group -> String? in
            guard let match = clauses.firstIndex(where: { clause in
                sameIdentifiers(clause.columns, group.columns)
                    && sameIdentifier(clause.referencedTable, group.referencedTable)
                    && (clause.referencedColumns.isEmpty
                        || sameIdentifiers(clause.referencedColumns, group.referencedColumns))
            }) else { return nil }
            let name = clauses[match].name
            clauses.remove(at: match)
            return name?.isEmpty == false ? name : nil
        }
    }

    private static func sameIdentifier(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: .caseInsensitive) == .orderedSame
    }

    private static func sameIdentifiers(_ lhs: [String], _ rhs: [String]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy(sameIdentifier)
    }
}
