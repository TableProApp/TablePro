//
//  MySQLForeignKeyCatalog.swift
//  MySQLDriverPlugin
//
//  The merge that replaces the server-side join of KEY_COLUMN_USAGE and REFERENTIAL_CONSTRAINTS.
//

import Foundation
import TableProPluginKit

internal enum MySQLForeignKeyCatalog {
    /// One `KEY_COLUMN_USAGE` row: a single column of a single foreign key.
    struct ColumnRow {
        let table: String
        let constraint: String
        let column: String
        let referencedSchema: String?
        let referencedTable: String
        let referencedColumn: String
    }

    /// One `REFERENTIAL_CONSTRAINTS` row: the two actions a whole foreign key carries.
    struct ActionRow {
        let table: String
        let constraint: String
        let onDelete: String
        let onUpdate: String
    }

    /// Merged in Swift rather than by the server, because ShardingSphere-Proxy 5.5.3 answers any
    /// join of two `information_schema` tables with an OK packet carrying no columns, while it
    /// answers each of the two reads correctly on its own.
    ///
    /// A column row with no action row keeps its key and takes `defaultAction`, which the old inner
    /// join dropped. Every server measured answers both catalogs or neither, so this only differs on
    /// a proxy that answers one of them.
    ///
    /// Row order is the caller's: the read orders by `ORDINAL_POSITION`, which is what puts a
    /// composite key's columns in declaration order.
    static func group(
        columnRows: [ColumnRow],
        actionRows: [ActionRow],
        defaultAction: String
    ) -> [String: [PluginForeignKeyInfo]] {
        var actions: [Identity: ActionRow] = [:]
        for row in actionRows {
            actions[Identity(table: row.table, constraint: row.constraint)] = row
        }

        var grouped: [String: [PluginForeignKeyInfo]] = [:]
        for row in columnRows {
            let action = actions[Identity(table: row.table, constraint: row.constraint)]
            grouped[row.table, default: []].append(
                PluginForeignKeyInfo(
                    name: row.constraint,
                    column: row.column,
                    referencedTable: row.referencedTable,
                    referencedColumn: row.referencedColumn,
                    referencedSchema: row.referencedSchema,
                    onDelete: action?.onDelete ?? defaultAction,
                    onUpdate: action?.onUpdate ?? defaultAction
                )
            )
        }
        return grouped
    }

    /// One table's keys out of an answer grouped by the server's own spelling of the table name.
    ///
    /// `KEY_COLUMN_USAGE.TABLE_NAME` collates case-insensitively, so `TABLE_NAME = 'OrderLines'`
    /// matches a table stored as `orderlines` and the rows come back under that name. Measured on
    /// MySQL 8.4.11 and MariaDB 11.4.13 with `lower_case_table_names = 1`, where `SHOW FULL COLUMNS`
    /// and `SHOW INDEX` both answer the caller's spelling, so a lookup keyed on it alone loses the
    /// foreign keys and nothing else. A grouped answer read for one table holds that table alone, so
    /// a single group is unambiguously it.
    static func keys(for table: String, in grouped: [String: [PluginForeignKeyInfo]]) -> [PluginForeignKeyInfo] {
        if let exact = grouped[table] { return exact }
        guard grouped.count == 1 else { return [] }
        return grouped.values.first ?? []
    }

    /// A constraint name is unique per database rather than per table, but the two catalogs are
    /// read per database, so the pair is what names one key on both sides.
    private struct Identity: Hashable {
        let table: String
        let constraint: String
    }
}
