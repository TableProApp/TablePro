//
//  RowChangeStatementFactoryAttachedDatabaseTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

/// SQLite resolves an unqualified table name in the main file first, so an edit to `auth.users` saved
/// as `UPDATE users` changes `main.users` when the main file has a table of that name.
@MainActor
struct RowChangeStatementFactoryAttachedDatabaseTests {
    private func factory(schema: String?, databaseType: DatabaseType = .sqlite) -> RowChangeStatementFactory {
        RowChangeStatementFactory(
            tableName: "users",
            schemaName: schema,
            columns: ["id", "email"],
            primaryKeyColumns: ["id"],
            databaseType: databaseType,
            pluginDriver: nil
        )
    }

    private let edit = RowChange(
        rowID: .existing(0),
        type: .update,
        cellChanges: [CellChange(columnIndex: 1, columnName: "email", oldValue: "a", newValue: "b")],
        originalRow: [.text("7"), "a"]
    )

    @Test("A save to a table in an attached database names that database in every statement")
    func attachedSaveIsQualified() throws {
        let inserted = RowID.inserted(UUID())
        let deleted = RowChange(rowID: .existing(1), type: .delete, originalRow: [.text("8"), "c"])
        let statements = try factory(schema: "auth").statements(
            for: [edit, RowChange(rowID: inserted, type: .insert), deleted],
            insertedRowData: [inserted: [.text("9"), "d"]],
            deletedRowIDs: [deleted.rowID],
            insertedRowIDs: [inserted]
        )
        #expect(statements.count == 3)
        for statement in statements {
            #expect(statement.sql.contains("`auth`.`users`"), "\(statement.sql)")
        }
    }

    @Test("A save to the main file stays unqualified, as does one on an engine whose schemas are switched")
    func otherSavesUnchanged() throws {
        let main = try factory(schema: nil).statements(for: [edit])
        #expect(main.first?.sql.contains("`users`") == true)
        #expect(main.first?.sql.contains("`auth`") == false)

        let postgres = try factory(schema: "billing", databaseType: .postgresql).statements(for: [edit])
        #expect(postgres.first?.sql.contains("billing") == false)
    }
}
