//
//  SQLiteColumnOrigins.swift
//  SQLiteDriverPlugin
//

import CSQLite
import Foundation
import TableProPluginKit

// SQLite traces a result column through aliases, subqueries, CTEs and views to the table column it reads, and reports
// none for an expression. A compound SELECT, a multi-row VALUES among them, reports one arm's column for the values of
// every arm, and a table-valued function such as json_each reports its own columns for whatever it was handed.
// Measured on SQLite 3.53.4.
enum SQLiteColumnOrigins {
    // Read after the first step, which may prepare the statement again, and only after one that did not fail:
    // `sqlite3_table_column_metadata` replaces the connection's error message.
    static func origins(of statement: OpaquePointer?, on db: OpaquePointer, text: String) -> [PluginColumnOrigin?]? {
        guard let statement else { return nil }
        let count = sqlite3_column_count(statement)
        guard count > 0 else { return [] }
        // Every column untrusted, not "no origins": nil would let a browse prove by name, and a filter value can hold the word.
        guard !hasCompoundSelect(text) else { return Array(repeating: nil, count: Int(count)) }
        let origins = (0..<count).map { origin(of: statement, column: $0, on: db) }
        guard origins.contains(where: { $0 != nil }) else { return origins }
        guard let shadows = shadowTables(on: db) else { return Array(repeating: nil, count: origins.count) }
        return origins.map { origin in
            origin.flatMap { shadows.contains(key(schema: $0.schema ?? "", table: $0.table)) ? nil : $0 }
        }
    }

    // An FTS table keeps a copy of its columns in shadow tables SQLite writes itself, under names no rule uses
    // (`c0`, `c1`). Measured on 3.53.4: `contacts_content.c0` passed the metadata lookup holding the addresses. A
    // failed lookup vouches for nothing.
    private static func shadowTables(on db: OpaquePointer) -> Set<String>? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        // The PRAGMA statement, not the pragma_table_list function: a read-only handle's authorizer allows the
        // reporting pragma and refuses reading the eponymous table.
        guard sqlite3_prepare_v2(db, "PRAGMA table_list", -1, &statement, nil) == SQLITE_OK else { return nil }
        var shadows: Set<String> = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            if let schema = sqlite3_column_text(statement, 0), let name = sqlite3_column_text(statement, 1),
               let type = sqlite3_column_text(statement, 2), String(cString: type) == "shadow" {
                shadows.insert(key(schema: String(cString: schema), table: String(cString: name)))
            }
            step = sqlite3_step(statement)
        }
        return step == SQLITE_DONE ? shadows : nil
    }

    private static func key(schema: String, table: String) -> String {
        "\(schema.lowercased()).\(table.lowercased())"
    }

    // Only a user table is vouched for: a `sqlite_` table is SQLite's own, and `sqlite_stat4.sample` holds the index
    // keys ANALYZE sampled. A table-valued function is no table in the schema, so the metadata lookup refuses it.
    private static func origin(of statement: OpaquePointer, column index: Int32, on db: OpaquePointer) -> PluginColumnOrigin? {
        guard let schema = sqlite3_column_database_name(statement, index),
              let table = sqlite3_column_table_name(statement, index),
              let column = sqlite3_column_origin_name(statement, index),
              !String(cString: table).lowercased().hasPrefix("sqlite_"),
              sqlite3_table_column_metadata(db, schema, table, column, nil, nil, nil, nil, nil) == SQLITE_OK
        else { return nil }
        return PluginColumnOrigin(
            schema: String(cString: schema), table: String(cString: table), column: String(cString: column)
        )
    }

    // `VALUES ((SELECT id FROM t)), ((SELECT email FROM users))` reports `t.id` for both rows.
    private static let compoundOperators: Set<String> = ["UNION", "INTERSECT", "EXCEPT", "VALUES"]

    // A word inside a literal or a comment counts too: it masks that one result whole.
    static func hasCompoundSelect(_ text: String) -> Bool {
        var word = ""
        for scalar in text.unicodeScalars {
            if scalar == "_" || scalar == "$" || CharacterSet.alphanumerics.contains(scalar) {
                word.unicodeScalars.append(scalar)
                continue
            }
            if compoundOperators.contains(word.uppercased()) { return true }
            word = ""
        }
        return compoundOperators.contains(word.uppercased())
    }
}
