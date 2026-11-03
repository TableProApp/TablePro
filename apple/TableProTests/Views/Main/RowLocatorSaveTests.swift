import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class SaveContextRecordingDriver: PluginDriverStub, @unchecked Sendable {
    private(set) var contexts: [PluginRowWriteContext] = []

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
        contexts.append(context)
        return changes.map { PluginRowWrite(statement: "updateOne(\($0.rowIndex))", rowIndices: [$0.rowIndex]) }
    }

    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }
}

@MainActor
struct RowLocatorSaveTests {
    private let stringLocator = #""507f1f77bcf86cd799439011""#
    private let objectIdLocator = #"{"$oid":"507f1f77bcf86cd799439011"}"#

    private func fixture(driver: SaveContextRecordingDriver) -> CoordinatorFixture {
        let fixture = CoordinatorFixture(connection: TestFixtures.makeConnection(database: "app", type: .mongodb))
        var tab = QueryTab(title: "users", query: "db.users.find({})", tabType: .table, tableName: "users")
        tab.execution.lastExecutedAt = Date()
        fixture.addTab(tab, rows: TableRows.from(
            queryRows: [
                [.text("507f1f77bcf86cd799439011"), .text("a")],
                [.text("507f1f77bcf86cd799439011"), .text("b")]
            ],
            columns: ["_id", "name"],
            columnTypes: [.text(rawType: nil), .text(rawType: nil)],
            hasAuthoritativeSchema: true,
            rowLocators: [stringLocator, objectIdLocator]
        ))
        fixture.changeManager.configureForTable(
            tableName: "users",
            columns: ["_id", "name"],
            primaryKeyColumns: ["_id"],
            databaseType: .mongodb,
            generatedColumns: []
        )
        fixture.changeManager.pluginDriver = driver
        return fixture
    }

    @Test("A grid save hands the driver the locator each edited row was read with, and the tab's database")
    func gridSaveCarriesLocators() throws {
        let driver = SaveContextRecordingDriver()
        let fixture = fixture(driver: driver)
        let coordinator = fixture.coordinator
        coordinator.changeManager.recordCellChange(
            rowID: .existing(1), columnIndex: 1, columnName: "name",
            oldValue: .text("b"), newValue: .text("z"),
            originalRow: [.text("507f1f77bcf86cd799439011"), .text("b")]
        )

        let plan = try coordinator.buildDataWritePlan(pendingTruncates: [], pendingDeletes: [], tableOperationOptions: [:])

        let context = try #require(driver.contexts.last)
        #expect(context.rowLocators == [0: objectIdLocator])
        #expect(context.database == "app")
        #expect(plan.rowOperations.map { $0.rowLocator } == [objectIdLocator])
    }

    @Test("An inspector save hands the driver each selected row's locator and the tab's database")
    func inspectorSaveCarriesLocators() throws {
        let driver = SaveContextRecordingDriver()
        let fixture = fixture(driver: driver)
        let coordinator = fixture.coordinator
        let tabId = try #require(coordinator.tabManager.selectedTabId)
        coordinator.gridModel(forTab: tabId).selectRows([.existing(0), .existing(1)])

        _ = try coordinator.sidebarEditStatements(
            editedFields: [InspectorFieldEdit(columnIndex: 1, columnName: "name", newValue: "z")]
        )

        let context = try #require(driver.contexts.last)
        #expect(context.rowLocators == [0: stringLocator, 1: objectIdLocator])
        #expect(context.database == "app")
    }
}
