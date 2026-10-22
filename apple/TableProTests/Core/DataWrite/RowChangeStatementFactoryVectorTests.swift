//
//  RowChangeStatementFactoryVectorTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct RowChangeStatementFactoryVectorTests {
    private let columns = ["id", "embedding", "note"]

    private func factory(types: [String: String] = ["id": "integer", "embedding": "vector(3)", "note": "text"])
        -> RowChangeStatementFactory {
        RowChangeStatementFactory(
            tableName: "items",
            schemaName: "public",
            columns: columns,
            primaryKeyColumns: ["id"],
            columnTypeNames: types,
            databaseType: .postgresql,
            pluginDriver: nil
        )
    }

    private func edit(_ value: String, column: String = "embedding", index: Int = 1) -> RowChange {
        RowChange(
            rowID: .existing(0),
            type: .update,
            cellChanges: [CellChange(columnIndex: index, columnName: column, oldValue: "[1,2,3]", newValue: .text(value))],
            originalRow: ["1", "[1,2,3]", "a"]
        )
    }

    private func refusal(_ changes: [RowChange], insertedRowData: [RowID: [PluginCellValue]] = [:]) -> String? {
        do {
            _ = try factory().statements(
                for: changes,
                insertedRowData: insertedRowData,
                insertedRowIDs: Set(insertedRowData.keys)
            )
            return nil
        } catch let DataWriteError.changeRefused(_, _, reason) {
            return reason
        } catch {
            Issue.record("Unexpected error: \(error)")
            return nil
        }
    }

    @Test("A value of the wrong length is refused before Save, naming the column and both counts")
    func wrongLengthIsRefused() throws {
        let reason = try #require(refusal([edit("[1,2]")]))
        #expect(reason.contains("embedding"))
        #expect(reason.contains("3"))
        #expect(reason.contains("2"))
    }

    @Test("A new row is checked from the values it was staged with")
    func insertIsChecked() {
        let rowID = RowID.inserted(UUID())
        let insert = RowChange(rowID: rowID, type: .insert)
        #expect(refusal([insert], insertedRowData: [rowID: ["1", "[1,2,3,4]", "a"]]) != nil)
        #expect(refusal([insert], insertedRowData: [rowID: ["1", "[1,2,3]", "a"]]) == nil)
    }

    @Test("A value of the right length, text the parser cannot read, and other columns all go to the server")
    func otherValuesPass() {
        #expect(refusal([edit("[4, 5, 6]")]) == nil)
        #expect(refusal([edit("[1,2")]) == nil)
        #expect(refusal([edit("[1,2]", column: "note", index: 2)]) == nil)
    }

    @Test("A column with no declared length is never refused")
    func unconstrainedColumnPasses() throws {
        let unconstrained = factory(types: ["id": "integer", "embedding": "vector", "note": "text"])
        _ = try unconstrained.statements(for: [edit("[1,2]")])
    }
}
