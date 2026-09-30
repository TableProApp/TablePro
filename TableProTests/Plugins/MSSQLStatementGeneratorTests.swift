//
//  MSSQLStatementGeneratorTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct MSSQLStatementGeneratorTests {
    private let columns = ["ID", "Status", "Qty"]

    private func generator(primaryKeys: [String] = ["ID"]) -> MSSQLStatementGenerator {
        MSSQLStatementGenerator(qualifiedTable: "[dbo].[defs]", columns: columns, primaryKeyColumns: primaryKeys)
    }

    private func update(_ column: String, to value: PluginCellValue) -> PluginRowChange {
        PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(columnIndex: 1, columnName: column, oldValue: .text("old"), newValue: value)],
            originalRow: [.text("1"), .text("old"), .text("1")]
        )
    }

    @Test
    func defaultMarkerInSetBecomesTheDefaultKeywordAndBindsNothing() throws {
        let statement = try #require(generator().updateStatement(for: update("Status", to: .text("__DEFAULT__"))))
        #expect(statement.statement == "UPDATE [dbo].[defs] SET [Status] = DEFAULT WHERE [ID] = ?")
        #expect(statement.parameters == [.text("1")])
    }

    @Test
    func ordinaryValueInSetIsBound() throws {
        let statement = try #require(generator().updateStatement(for: update("Status", to: .text("new"))))
        #expect(statement.statement == "UPDATE [dbo].[defs] SET [Status] = ? WHERE [ID] = ?")
        #expect(statement.parameters == [.text("new"), .text("1")])
    }

    @Test
    func keylessUpdateMatchesEveryColumnAndTouchesOneRow() throws {
        let statement = try #require(generator(primaryKeys: []).updateStatement(for: update("Status", to: .text("new"))))
        #expect(
            statement.statement
                == "UPDATE TOP (1) [dbo].[defs] SET [Status] = ? WHERE [ID] = ? AND [Status] = ? AND [Qty] = ?"
        )
        #expect(statement.parameters == [.text("new"), .text("1"), .text("old"), .text("1")])
    }

    @Test
    func insertLeavesDefaultMarkedColumnsOut() {
        let statement = generator().insertStatement(values: [.text("__DEFAULT__"), .text("open"), .text("__DEFAULT__")])
        #expect(statement.statement == "INSERT INTO [dbo].[defs] ([Status]) VALUES (?)")
        #expect(statement.parameters == [.text("open")])
    }

    @Test
    func insertOfOnlyDefaultsUsesDefaultValues() {
        let marker = PluginCellValue.text("__DEFAULT__")
        let statement = generator().insertStatement(values: [marker, marker, marker])
        #expect(statement.statement == "INSERT INTO [dbo].[defs] DEFAULT VALUES")
        #expect(statement.parameters.isEmpty)
    }

    @Test
    func updateWithoutCellChangesWritesNothing() {
        let probe = PluginRowChange(rowIndex: 0, type: .update, cellChanges: [], originalRow: nil)
        let statements = generator().statements(
            for: [probe], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
        )
        #expect(statements.isEmpty)
    }

    @Test
    func keylessDeleteTouchesOneRow() throws {
        let change = PluginRowChange(
            rowIndex: 0, type: .delete, cellChanges: [], originalRow: [.text("1"), .null, .text("2")]
        )
        let statement = try #require(generator(primaryKeys: []).deleteStatement(for: change))
        #expect(statement.statement == "DELETE TOP (1) FROM [dbo].[defs] WHERE [ID] = ? AND [Status] IS NULL AND [Qty] = ?")
        #expect(statement.parameters == [.text("1"), .text("2")])
    }

    @Test
    func deletesFollowEveryOtherWrite() {
        let delete = PluginRowChange(rowIndex: 1, type: .delete, cellChanges: [], originalRow: [.text("2"), .null, .null])
        let insert = PluginRowChange(rowIndex: 2, type: .insert, cellChanges: [], originalRow: nil)
        let statements = generator().statements(
            for: [delete, insert],
            insertedRowData: [2: [.text("__DEFAULT__"), .text("a"), .text("3")]],
            deletedRowIndices: [1],
            insertedRowIndices: [2]
        )
        #expect(statements.map(\.statement) == [
            "INSERT INTO [dbo].[defs] ([Status], [Qty]) VALUES (?, ?)",
            "DELETE FROM [dbo].[defs] WHERE [ID] = ?"
        ])
    }
}
