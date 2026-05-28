import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("FKNavigation")
struct FKNavigationTests {
    @Test("makeFKReferencePayload targets the referenced table and carries the FK filter")
    @MainActor
    func payloadCarriesFilterAndTarget() {
        let connection = TestFixtures.makeConnection(database: "db")
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: QueryTabManager(),
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }

        let filter = TableFilter(columnName: "id", filterOperator: .equal, value: "42")
        let payload = coordinator.makeFKReferencePayload(
            filter: filter,
            referencedTable: "users",
            databaseName: "db",
            schemaName: nil
        )

        #expect(payload.connectionId == connection.id)
        #expect(payload.tabType == .table)
        #expect(payload.tableName == "users")
        #expect(payload.databaseName == "db")
        #expect(payload.isView == false)
        #expect(payload.initialFilterState?.filters == [filter])
        #expect(payload.initialFilterState?.appliedFilters == [filter])
        #expect(payload.initialFilterState?.isVisible == true)
    }

    @Test("Plain click navigates the referenced table into the current tab")
    @MainActor
    func plainClickReplacesCurrentTab() throws {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }

        try tabManager.addTableTab(
            tableName: "orders",
            databaseType: connection.type,
            databaseName: coordinator.activeDatabaseName
        )
        #expect(tabManager.tabs.count == 1)

        let fkInfo = TestFixtures.makeForeignKeyInfo(referencedTable: "users", referencedColumn: "id")
        coordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, openInNewTab: false)

        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.selectedTab?.tableContext.tableName == "users")
    }

    @Test("Plain click on the already-open referenced table does not open a second tab")
    @MainActor
    func plainClickOnSameTableStaysInPlace() throws {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }

        try tabManager.addTableTab(
            tableName: "users",
            databaseType: connection.type,
            databaseName: coordinator.activeDatabaseName
        )
        let tabId = tabManager.selectedTab?.id
        #expect(tabManager.tabs.count == 1)

        let fkInfo = TestFixtures.makeForeignKeyInfo(referencedTable: "users", referencedColumn: "id")
        coordinator.navigateToFKReference(value: "42", fkInfo: fkInfo, openInNewTab: false)

        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.selectedTab?.id == tabId)
        #expect(tabManager.selectedTab?.tableContext.tableName == "users")
    }
}
