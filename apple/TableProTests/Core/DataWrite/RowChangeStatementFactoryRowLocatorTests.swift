import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class LocatorRecordingDriver: PluginDriverStub, @unchecked Sendable {
    private(set) var context: PluginRowWriteContext?
    private(set) var changes: [PluginRowChange] = []

    func generateRowWrites(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>,
        context: PluginRowWriteContext
    ) throws -> [PluginRowWrite]? {
        self.context = context
        self.changes = changes
        return changes.map { PluginRowWrite(statement: "WRITE", rowIndices: [$0.rowIndex]) }
    }

    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }
}

@MainActor
struct RowChangeStatementFactoryRowLocatorTests {
    private func factory(_ driver: LocatorRecordingDriver) -> RowChangeStatementFactory {
        RowChangeStatementFactory(
            tableName: "users",
            schemaName: nil,
            columns: ["_id", "name"],
            primaryKeyColumns: ["_id"],
            databaseType: .mongodb,
            pluginDriver: driver
        )
    }

    private func edit(row: Int, sequence: Int) -> RowChange {
        RowChange(
            rowID: .existing(row),
            type: .update,
            cellChanges: [CellChange(columnIndex: 1, columnName: "name", oldValue: "old", newValue: "new")],
            originalRow: ["507f1f77bcf86cd799439011", "old"],
            sequence: sequence
        )
    }

    @Test("Each change reaches the driver with the locator its row was read with, under the change's own index")
    func locatorsFollowTheirChanges() throws {
        let driver = LocatorRecordingDriver()
        var factory = factory(driver)
        factory.rowLocators = [
            .existing(7): #""507f1f77bcf86cd799439011""#,
            .existing(3): #"{"$oid":"507f1f77bcf86cd799439011"}"#,
            .existing(9): #""unrelated""#
        ]
        factory.database = "app"
        let delete = RowChange(
            rowID: .existing(3), type: .delete, originalRow: ["507f1f77bcf86cd799439011", "old"], sequence: 2
        )

        _ = try factory.statements(for: [edit(row: 7, sequence: 1), delete], deletedRowIDs: [.existing(3)])

        let context = try #require(driver.context)
        #expect(driver.changes.map { $0.rowIndex } == [0, 1])
        #expect(driver.changes.map { $0.type } == [.update, .delete])
        #expect(context.rowLocators == [
            0: #""507f1f77bcf86cd799439011""#,
            1: #"{"$oid":"507f1f77bcf86cd799439011"}"#
        ])
        #expect(context.database == "app")
    }

    @Test("A row the read gave no locator reaches the driver without one, for the driver to refuse")
    func rowWithoutLocatorHasNone() throws {
        let driver = LocatorRecordingDriver()
        var factory = factory(driver)
        factory.rowLocators = [.existing(1): #""a""#]

        _ = try factory.statements(for: [edit(row: 0, sequence: 1)])

        let context = try #require(driver.context)
        #expect(context.rowLocators.isEmpty)
        #expect(context.database == nil)
    }

    @Test("A save hands the driver the database it runs in and the locators of the tab's rows")
    func saveCarriesTheScopeDatabaseAndLocators() throws {
        let driver = LocatorRecordingDriver()
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "users", columns: ["_id", "name"], primaryKeyColumns: ["_id"],
            databaseType: .mongodb, generatedColumns: []
        )
        manager.pluginDriver = driver
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: .text("old"), newValue: .text("new"),
            originalRow: [.text("123"), .text("old")]
        )

        _ = try manager.buildRowWrites(
            database: "app", schema: nil, containsTableOperation: false,
            rowLocators: [.existing(0): #""123""#]
        )

        let context = try #require(driver.context)
        #expect(context.database == "app")
        #expect(context.rowLocators == [0: #""123""#])
    }
}
