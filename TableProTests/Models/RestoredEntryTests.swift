//
//  RestoredEntryTests.swift
//  TableProTests
//

@testable import TablePro
import Testing

struct RestoredEntryTests {
    private func tab(database: String) -> QueryTab {
        var tab = QueryTab(title: "orders", tabType: .table, tableName: "orders")
        tab.tableContext.databaseName = database
        return tab
    }

    /// An entry with no tab of its own saves the connection's first tab as selected, so the saved
    /// selection names another database than the one that was on screen.
    @Test("A restore lands on the database the connection was last on, not the saved first tab")
    func savedDatabaseWinsOverASavedTab() {
        let entry = RestoredEntry.resolve(
            selected: tab(database: "tenant_a"),
            isPresent: false,
            target: .database,
            activeDatabase: "tenant_b",
            activeSchema: nil
        )
        #expect(entry == RestoredEntry(container: "tenant_b", database: "tenant_b", schema: nil))
    }

    @Test("A tab a link opened before the restore keeps its own database")
    func presentTabWins() {
        let entry = RestoredEntry.resolve(
            selected: tab(database: "tenant_a"),
            isPresent: true,
            target: .database,
            activeDatabase: "tenant_b",
            activeSchema: "public"
        )
        #expect(entry == RestoredEntry(container: "tenant_a", database: "tenant_a", schema: nil))
    }

    @Test("With no database saved the selected tab decides")
    func selectedTabDecidesWithoutASavedDatabase() {
        let entry = RestoredEntry.resolve(
            selected: tab(database: "tenant_a"),
            isPresent: false,
            target: .database,
            activeDatabase: nil,
            activeSchema: nil
        )
        #expect(entry.container == "tenant_a")
    }
}
