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
        let statement = try #require(try generator().updateStatement(for: update("Status", to: .text("__DEFAULT__"))))
        #expect(statement.statement == "UPDATE [dbo].[defs] SET [Status] = DEFAULT WHERE [ID] = ?")
        #expect(statement.parameters == [.text("1")])
    }

    @Test
    func ordinaryValueInSetIsBound() throws {
        let statement = try #require(try generator().updateStatement(for: update("Status", to: .text("new"))))
        #expect(statement.statement == "UPDATE [dbo].[defs] SET [Status] = ? WHERE [ID] = ?")
        #expect(statement.parameters == [.text("new"), .text("1")])
    }

    @Test
    func keylessUpdateMatchesEveryColumnAndTouchesOneRow() throws {
        let statement = try #require(try generator(primaryKeys: []).updateStatement(for: update("Status", to: .text("new"))))
        #expect(
            statement.statement
                == "SET NOCOUNT OFF; UPDATE TOP (1) [dbo].[defs] SET [Status] = ? WHERE [ID] = ? AND [Status] = ? AND [Qty] = ?"
        )
        #expect(statement.parameters == [.text("new"), .text("1"), .text("old"), .text("1")])
    }

    @Test
    func keylessMatchOnAnEmptyStringComparesItRatherThanAskingForNull() throws {
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(columnIndex: 1, columnName: "Status", oldValue: .text(""), newValue: .text("new"))],
            originalRow: [.text("1"), .text(""), .null]
        )
        let statement = try #require(try generator(primaryKeys: []).updateStatement(for: change))
        #expect(statement.statement.hasSuffix("WHERE [ID] = ? AND [Status] = ? AND [Qty] IS NULL"))
        #expect(statement.parameters == [.text("new"), .text("1"), .text("")])
    }

    @Test
    func anUnboundKeylessWriteSetsTheCountInAScopeOfItsOwn() throws {
        let change = PluginRowChange(rowIndex: 0, type: .delete, cellChanges: [], originalRow: [.null, .null, .null])
        let statement = try #require(try generator(primaryKeys: []).deleteStatement(for: change))
        #expect(
            statement.statement
                == "EXEC sp_executesql N'SET NOCOUNT OFF; DELETE TOP (1) FROM [dbo].[defs] WHERE [ID] IS NULL AND [Status] IS NULL AND [Qty] IS NULL'"
        )
        #expect(statement.parameters.isEmpty)
    }

    @Test
    func keyedWritesLeaveTheSessionsCountSettingAlone() throws {
        let change = update("Status", to: .text("new"))
        let written = try #require(try generator().updateStatement(for: change))
        let deleted = try #require(try generator().deleteStatement(for: change))
        #expect(!written.statement.contains("NOCOUNT"))
        #expect(!deleted.statement.contains("NOCOUNT"))
    }

    @Test
    func insertLeavesDefaultMarkedColumnsOut() throws {
        let statement = try generator().insertStatement(values: [.text("__DEFAULT__"), .text("open"), .text("__DEFAULT__")])
        #expect(statement.statement == "INSERT INTO [dbo].[defs] ([Status]) VALUES (?)")
        #expect(statement.parameters == [.text("open")])
    }

    @Test
    func insertOfOnlyDefaultsUsesDefaultValues() throws {
        let marker = PluginCellValue.text("__DEFAULT__")
        let statement = try generator().insertStatement(values: [marker, marker, marker])
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
        let statement = try #require(try generator(primaryKeys: []).deleteStatement(for: change))
        #expect(
            statement.statement
                == "SET NOCOUNT OFF; DELETE TOP (1) FROM [dbo].[defs] WHERE [ID] = ? AND [Status] IS NULL AND [Qty] = ?"
        )
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

    private func keyless(context: PluginRowWriteContext) -> MSSQLStatementGenerator {
        var generator = MSSQLStatementGenerator(qualifiedTable: "[dbo].[notes]", columns: ["a", "n", "s"], primaryKeyColumns: [])
        generator.context = context
        return generator
    }

    private func keylessEdit(original: [PluginCellValue]) -> PluginRowChange {
        PluginRowChange(
            rowIndex: 4,
            type: .update,
            cellChanges: [(columnIndex: 2, columnName: "s", oldValue: original[2], newValue: .text("EDITED"))],
            originalRow: original
        )
    }

    @Test
    func keylessMatchWithAColumnLeftOutIsRefusedRatherThanWritingAnotherRow() {
        var context = PluginRowWriteContext()
        context.rowMatchExcludedColumns = ["n"]
        let change = keylessEdit(original: [.text("1"), .text("second"), .text("keep")])
        #expect(throws: PluginRowWriteRefusal.self) {
            _ = try keyless(context: context).updateStatement(for: change)
        }
        #expect(throws: PluginRowWriteRefusal.self) {
            _ = try keyless(context: context).deleteStatement(for: change)
        }
    }

    @Test
    func keylessMatchCastsTextPolicyColumnsToTheBoundType() throws {
        var context = PluginRowWriteContext()
        context.rowMatchTextColumns = ["n", "s"]
        let change = keylessEdit(original: [.text("1"), .text("long text"), .bytes(Data([0x01]))])
        let statement = try #require(try keyless(context: context).updateStatement(for: change))
        #expect(statement.statement.hasSuffix(
            "WHERE [a] = ? AND CAST([n] AS NVARCHAR(MAX)) = ? AND CAST([s] AS VARBINARY(MAX)) = ?"
        ))
    }

    @Test
    func anUpdateOfAServerOwnedColumnIsRefused() {
        var owning = generator()
        owning.context.serverOwnedColumns = ["ID"]
        let change = PluginRowChange(
            rowIndex: 2,
            type: .update,
            cellChanges: [(columnIndex: 0, columnName: "ID", oldValue: .text("1761"), newValue: .text("1890"))],
            originalRow: [.text("1761"), .text("old"), .text("1")]
        )
        do {
            _ = try owning.updateStatement(for: change)
            Issue.record("An IDENTITY column was assigned")
        } catch let refusal as PluginRowWriteRefusal {
            #expect(refusal.rowIndex == 2)
            #expect(refusal.reason.contains("ID"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func anInsertCarryingAValueForAServerOwnedColumnIsRefused() {
        var owning = generator()
        owning.context.serverOwnedColumns = ["ID"]
        #expect(throws: PluginRowWriteRefusal.self) {
            _ = try owning.insertStatement(values: [.text("7"), .text("a"), .text("1")], rowIndex: 1)
        }
    }

    @Test
    func eachWriteNamesTheChangeItCarriesOut() throws {
        let first = update("Status", to: .text("x"))
        let second = PluginRowChange(
            rowIndex: 3,
            type: .update,
            cellChanges: [(columnIndex: 2, columnName: "Qty", oldValue: .text("1"), newValue: .text("2"))],
            originalRow: [.text("2"), .text("b"), .text("1")]
        )
        let writes = try generator().rowWrites(
            for: [first, second], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
        )
        #expect(writes.map(\.rowIndices) == [[0], [3]])
    }
}
