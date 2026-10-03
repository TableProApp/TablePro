//
//  CassandraRowWriterTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct CassandraRowWriterTests {
    private let columns = ["tenant", "day", "ts", "name", "n"]
    private let primaryKey = ["tenant", "day", "ts"]
    private let original: [PluginCellValue] = [.text("acme"), .text("2024-01-01"), .text("5"), .text("x"), .text("1")]

    private func writes(_ changes: [PluginRowChange], inserted: [Int: [PluginCellValue]] = [:]) throws -> [PluginRowWrite] {
        try CassandraRowWriter.rowWrites(
            keyspace: "shop", table: "events", columns: columns, primaryKeyColumns: primaryKey,
            changes: changes, insertedRowData: inserted
        )
    }

    private func refusal(_ change: PluginRowChange, inserted: [Int: [PluginCellValue]] = [:]) -> PluginRowWriteRefusal? {
        do {
            _ = try writes([change], inserted: inserted)
            return nil
        } catch let refusal as PluginRowWriteRefusal {
            return refusal
        } catch {
            return nil
        }
    }

    @Test("Deleting several rows sends one DELETE each, named by the whole primary key")
    func deletesAreOnePerRow() throws {
        let result = try writes([
            PluginRowChange(rowIndex: 0, type: .delete, cellChanges: [], originalRow: original),
            PluginRowChange(rowIndex: 1, type: .delete, cellChanges: [], originalRow: original)
        ])

        #expect(result.count == 2)
        #expect(result[0].statement == #"DELETE FROM "shop"."events" WHERE "tenant" = ? AND "day" = ? AND "ts" = ?"#)
        #expect(result[0].parameters == [.text("acme"), .text("2024-01-01"), .text("5")])
        #expect(result.map(\.rowIndices) == [[0], [1]])
        #expect(!result.contains { $0.statement.contains(" OR ") || $0.statement.contains("(") })
    }

    @Test("An update sets only the changed cells and binds the key after them")
    func updateBindsValuesThenKey() throws {
        let change = PluginRowChange(
            rowIndex: 3, type: .update,
            cellChanges: [(columnIndex: 3, columnName: "name", oldValue: .text("x"), newValue: .text("y"))],
            originalRow: original
        )

        let result = try writes([change])

        #expect(result.first?.statement
            == #"UPDATE "shop"."events" SET "name" = ? WHERE "tenant" = ? AND "day" = ? AND "ts" = ?"#)
        #expect(result.first?.parameters == [.text("y"), .text("acme"), .text("2024-01-01"), .text("5")])
    }

    @Test("An update with nothing changed writes nothing and refuses nothing")
    func emptyUpdateWritesNothing() throws {
        let change = PluginRowChange(rowIndex: 0, type: .update, cellChanges: [], originalRow: original)
        #expect(try writes([change]).isEmpty)
    }

    @Test("A new row is written IF NOT EXISTS, leaving out the cells left at the default")
    func insertIsConditional() throws {
        let change = PluginRowChange(rowIndex: 7, type: .insert, cellChanges: [], originalRow: nil)
        let row: [PluginCellValue] = [.text("acme"), .text("2024-01-02"), .text("now()"), .text("__DEFAULT__"), .null]

        let result = try writes([change], inserted: [7: row])

        #expect(result.first?.statement
            == #"INSERT INTO "shop"."events" ("tenant", "day", "ts", "n") VALUES (?, ?, now(), ?) IF NOT EXISTS"#)
        #expect(result.first?.parameters == [.text("acme"), .text("2024-01-02"), .null])
        #expect(result.first?.rowIndices == [7])
    }

    @Test("A new row missing part of its primary key is refused by the column's name")
    func insertNeedsTheWholeKey() {
        let change = PluginRowChange(rowIndex: 2, type: .insert, cellChanges: [], originalRow: nil)
        let row: [PluginCellValue] = [.text("acme"), .null, .text("1"), .text("x"), .text("1")]

        #expect(refusal(change, inserted: [2: row])?.reason.contains("day") == true)
    }

    @Test("Changing a primary key cell is refused rather than written as an upsert of a new row")
    func keyChangeIsRefused() {
        let change = PluginRowChange(
            rowIndex: 1, type: .update,
            cellChanges: [(columnIndex: 0, columnName: "tenant", oldValue: .text("acme"), newValue: .text("globex"))],
            originalRow: original
        )

        #expect(refusal(change)?.rowIndex == 1)
    }

    @Test("Setting a column to its default is refused, because CQL has none")
    func defaultIsRefused() {
        let change = PluginRowChange(
            rowIndex: 0, type: .update,
            cellChanges: [(columnIndex: 3, columnName: "name", oldValue: .text("x"), newValue: .text("__DEFAULT__"))],
            originalRow: original
        )

        #expect(refusal(change) != nil)
    }

    @Test("A row whose key was not loaded is refused instead of matching another row")
    func missingKeyIsRefused() {
        var partial = original
        partial[1] = .null
        let deletion = PluginRowChange(rowIndex: 4, type: .delete, cellChanges: [], originalRow: partial)
        let noOriginal = PluginRowChange(rowIndex: 5, type: .delete, cellChanges: [], originalRow: nil)

        #expect(refusal(deletion)?.rowIndex == 4)
        #expect(refusal(noOriginal)?.rowIndex == 5)
    }

    @Test("A table with no known primary key refuses every write")
    func unknownKeyRefusesWrites() {
        let insert = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        #expect(throws: PluginRowWriteRefusal.self) {
            try CassandraRowWriter.rowWrites(
                keyspace: nil, table: "t", columns: ["a"], primaryKeyColumns: [], changes: [insert],
                insertedRowData: [0: [.text("1")]]
            )
        }
    }

    @Test("Undoing a delete writes the row back whole, with a plain INSERT")
    func restoreWritesTheRowBack() {
        let restored = CassandraRowWriter.restoreInserts(
            keyspace: "shop", table: "events", columns: columns, rows: [original]
        )

        #expect(restored.count == 1)
        #expect(restored.first?.statement
            == #"INSERT INTO "shop"."events" ("tenant", "day", "ts", "name", "n") VALUES (?, ?, ?, ?, ?)"#)
        #expect(restored.first?.parameters == original)
    }

    @Test("An insert the server did not apply because the key is taken is a refusal, anything else is not")
    func unappliedInsertIsNamed() {
        let insert = #"INSERT INTO "t" ("id") VALUES (?) IF NOT EXISTS"#
        let taken = CassandraRowWriter.unappliedInsertRefusal(
            statement: insert, columns: ["[applied]", "id"], rows: [[.text("false"), .text("1")]]
        )
        let applied = CassandraRowWriter.unappliedInsertRefusal(
            statement: insert, columns: ["[applied]"], rows: [[.text("true")]]
        )
        let update = CassandraRowWriter.unappliedInsertRefusal(
            statement: #"UPDATE "t" SET "a" = ? WHERE "id" = ? IF EXISTS"#, columns: ["[applied]"], rows: [[.text("false")]]
        )

        #expect(taken != nil)
        #expect(applied == nil)
        #expect(update == nil)
    }
}
