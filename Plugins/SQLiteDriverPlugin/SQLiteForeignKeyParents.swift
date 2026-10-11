//
//  SQLiteForeignKeyParents.swift
//  SQLiteDriverPlugin
//
//  Which parent tables a set of PRAGMA foreign_key_list rows points at.
//  Compiled into the test target via project.yml.
//

import Foundation
import TableProPluginKit

/// The one question both foreign key reads have to ask before they can resolve a shorthand
/// `REFERENCES parent`.
///
/// `PRAGMA foreign_key_list` reports a null target column for that form, so the parent's own
/// primary key has to be fetched and handed to the grouping. The single-table read asked it and
/// the bulk read did not, which is two call sites of one grouping function that must agree with
/// nothing forcing them to: the bulk result named the child's own column as the target, and every
/// surface reading the cached bulk answer followed a column the parent does not have.
enum SQLiteForeignKeyParents {
    /// `rows` are `PRAGMA foreign_key_list` rows with the table name already stripped, so the
    /// referenced table sits at index 2, the position the grouping reads it from.
    static func referencedTables(in rows: [[PluginCellValue]]) -> [String] {
        rows.compactMap { $0[safe: 2]?.asText }
    }

    static func referencedTables(in rowsByTable: [String: [[PluginCellValue]]]) -> [String] {
        rowsByTable.values.flatMap(referencedTables)
    }
}
