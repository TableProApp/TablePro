//
//  StructureChangeManagerForeignKeyLoadTests.swift
//  TableProTests
//
//  Foreign keys read one row per column, loaded into the structure editor.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct StructureChangeManagerForeignKeyLoadTests {
    private static let rows = [
        ForeignKeyInfo(
            name: "fk_b", column: "b2", referencedTable: "parent_b", referencedColumn: "pb2",
            referencedSchema: "ref", onDelete: "cascade", onUpdate: "set null"
        ),
        ForeignKeyInfo(name: "fk_a", column: "a1", referencedTable: "parent_a", referencedColumn: "pa1"),
        ForeignKeyInfo(
            name: "fk_b", column: "b1", referencedTable: "ignored", referencedColumn: "pb1",
            referencedSchema: "ignored", onDelete: "RESTRICT", onUpdate: "RESTRICT"
        ),
        ForeignKeyInfo(
            name: "Fk_c", column: "c1", referencedTable: "parent_c", referencedColumn: "pc1", onDelete: "bogus"
        )
    ]

    @MainActor private func loadedKeys() -> [EditableForeignKeyDefinition] {
        let manager = StructureChangeManager()
        manager.loadSchema(
            tableName: "child",
            columns: ["a1", "b1", "b2", "c1"].map {
                ColumnInfo(name: $0, dataType: "INTEGER", isNullable: true, isPrimaryKey: false)
            },
            indexes: [],
            foreignKeys: Self.rows,
            primaryKey: []
        )
        return manager.currentForeignKeys
    }

    @Test("Keys are listed by name")
    @MainActor func keysAreOrderedByName() {
        #expect(loadedKeys().map(\.name) == ["Fk_c", "fk_a", "fk_b"])
    }

    @Test("The rows of one key become one definition, in the order the columns were read")
    @MainActor func rowsOfOneKeyAreGrouped() throws {
        let composite = try #require(loadedKeys().first { $0.name == "fk_b" })
        #expect(composite.columns == ["b2", "b1"])
        #expect(composite.referencedColumns == ["pb2", "pb1"])
    }

    @Test("A key takes its identity, table, schema and actions from its first row")
    @MainActor func keyReadsItsFirstRow() throws {
        let composite = try #require(loadedKeys().first { $0.name == "fk_b" })
        #expect(composite.id == Self.rows[0].id)
        #expect(composite.referencedTable == "parent_b")
        #expect(composite.referencedSchema == "ref")
        #expect(composite.onDelete == .cascade)
        #expect(composite.onUpdate == .setNull)
    }

    @Test("An action the editor has no case for reads as NO ACTION")
    @MainActor func unknownActionIsNoAction() throws {
        let key = try #require(loadedKeys().first { $0.name == "Fk_c" })
        #expect(key.onDelete == .noAction)
        #expect(key.onUpdate == .noAction)
    }
}
