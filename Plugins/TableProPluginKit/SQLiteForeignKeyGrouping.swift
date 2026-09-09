//
//  SQLiteForeignKeyGrouping.swift
//  TableProPluginKit
//

import Foundation

/// Turns SQLite's `PRAGMA foreign_key_list` rows into the foreign keys a schema editor can show.
///
/// The pragma resolves what the DDL leaves implicit: `REFERENCES parent` with no column list comes
/// back naming the parent's actual primary key. What it cannot supply is the constraint's name,
/// which it does not report at all, so a key the user declared as
/// `CONSTRAINT fk_orders_customer …` reads back anonymous and the name they typed is lost the next
/// time the table is read.
///
/// So both are used: the pragma for the resolved columns, and the stored `CREATE TABLE` text for
/// the name. They are matched on the relationship each describes rather than on position, because
/// the pragma numbers keys in reverse declaration order and renumbers them whenever one is added or
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
        createTableSQL: String?
    ) -> [PluginForeignKeyInfo] {
        let groups = groups(from: pragmaRows)
        let names = declaredNames(for: groups, createTableSQL: createTableSQL)

        return groups.enumerated().flatMap { offset, group -> [PluginForeignKeyInfo] in
            let name = names[offset] ?? "fk_\(table)_\(group.id)"
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

    private static func groups(from rows: [[PluginCellValue]]) -> [Group] {
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
            /// A `REFERENCES parent` with no column list reports the resolved parent key here, and
            /// reports null only when the parent has no primary key at all, which is a key SQLite
            /// will refuse anyway.
            groups[index].referencedColumns.append(row[safe: 4]?.asText ?? column)
            if let onUpdate = row[safe: 5]?.asText { groups[index].onUpdate = onUpdate }
            if let onDelete = row[safe: 6]?.asText { groups[index].onDelete = onDelete }
        }
        return groups
    }

    /// The `CONSTRAINT` name the DDL gave each group, where it gave one.
    ///
    /// Matched on the child columns and the parent table, which is what both sides always carry.
    /// The parent columns are deliberately not compared: the DDL may omit them and the pragma
    /// always resolves them, so requiring them to agree would fail exactly the keys written in the
    /// shorter form.
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
