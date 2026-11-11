import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

@MainActor
struct TableLoadAfterSafeModePromptTests {
    @Test("A table load turned away while a query waits for approval runs once that approval closes")
    func turnedAwayLoadRunsAfterThePrompt() async throws {
        let connection = DatabaseConnection(
            name: "Confirm", database: "app", type: .postgresql, safeModeLevel: .alertFull
        )
        let fixture = CoordinatorFixture(
            connection: connection,
            driver: ScriptAnsweringDriver(connection: connection, sendsBatchesWhole: false)
        )
        fixture.coordinator.toolbarState.safeModeLevel = .alertFull
        let gate = HeldExecutionGate()
        fixture.coordinator.executionGate = gate
        defer { fixture.coordinator.cancelAllQueryTasks() }

        fixture.addTab(QueryTab(title: "Query", query: "SELECT 1", tabType: .query))
        #expect(fixture.coordinator.runStatement("SELECT 1"))
        try await waitUntil { gate.askedCount == 1 }

        var table = QueryTab(title: "users", query: "SELECT * FROM users LIMIT 1000", tabType: .table, tableName: "users")
        table.pagination.isLoading = true
        fixture.addTab(table)
        #expect(fixture.coordinator.executeTableTabQueryDirectly(viewport: .firstRow) == nil)
        #expect(fixture.tabManager.tabs.first { $0.id == table.id }?.pagination.isLoading == false)

        await gate.answer(allowing: true)
        try await waitUntil { gate.askedCount == 2 }
        await gate.answer(allowing: false)
        try await waitUntil {
            fixture.tabManager.tabs.first { $0.id == table.id }?.execution.errorMessage == "Refused by the test"
        }
    }
}
