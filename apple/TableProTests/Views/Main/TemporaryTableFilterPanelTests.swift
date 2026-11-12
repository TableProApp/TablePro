//
//  TemporaryTableFilterPanelTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

extension GlobalStateSuites {
    /// A temporary table restores no saved filters, since they are keyed by a name it shares with the permanent table
    /// it hides, and still opens its filter panel when the data view setting asks for one with each table.
    @Suite(.appSettings { $0.dataGrid.opensFilterPanelForTables = true })
    @MainActor
    struct TemporaryTableFilterPanelTests {
        private let fixture = CoordinatorFixture()
        private let temporary = TableInfo(name: "orders", type: .table, rowCount: nil, isTemporary: true)

        private func openTab() throws -> QueryTab {
            try #require(fixture.tabManager.selectedTab)
        }

        @Test("A temporary table opens with the filter panel, as every table does")
        func opensThePanel() throws {
            fixture.coordinator.openTableTab(temporary)

            let tab = try openTab()
            #expect(tab.tableContext.isTemporary)
            #expect(tab.filterState.isVisible)
            #expect(tab.filterState.filters.isEmpty)
        }

        @Test("Going back to an open temporary table leaves a panel the reader closed closed")
        func opensOnlyOnFirstOpen() throws {
            fixture.coordinator.openTableTab(temporary)
            let index = try #require(fixture.tabManager.selectedTabIndex)
            fixture.tabManager.mutate(at: index) { $0.filterState.isVisible = false }

            fixture.coordinator.openTableTab(temporary)

            #expect(fixture.tabManager.tabs.count == 1)
            #expect(try openTab().filterState.isVisible == false)
        }

        @Test(
            "With the setting off a temporary table opens without the panel",
            .appSettings { $0.dataGrid.opensFilterPanelForTables = false }
        )
        func settingOffLeavesThePanelClosed() throws {
            fixture.coordinator.openTableTab(temporary)

            #expect(try openTab().filterState.isVisible == false)
        }
    }
}
