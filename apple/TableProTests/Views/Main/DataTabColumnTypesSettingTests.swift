//
//  DataTabColumnTypesSettingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

extension GlobalStateSuites {
    @MainActor
    struct DataTabColumnTypesSettingTests {
        private func configuration() -> DataGridConfiguration {
            let fixture = CoordinatorFixture()
            let tab = fixture.addTab(QueryTab(title: "orders", query: "SELECT * FROM orders", tabType: .table, tableName: "orders"))
            return fixture.coordinator.gridConfiguration(for: tab)
        }

        @Test("A data tab's grid shows column types while the Data Grid setting is on",
              .appSettings { $0.dataGrid.showsColumnTypesInHeader = true })
        func settingOnShowsTypes() {
            #expect(configuration().showsColumnTypes)
        }

        @Test("A data tab's grid has one header line while the setting is off",
              .appSettings { $0.dataGrid.showsColumnTypesInHeader = false })
        func settingOffHidesTypes() {
            #expect(!configuration().showsColumnTypes)
        }

        @Test("A grid no setting reaches keeps one header line")
        func plainGridHasNoTypes() {
            #expect(!DataGridConfiguration().showsColumnTypes)
            #expect(!DataGridConfiguration().namesDeclaredColumnTypes)
        }

        @Test("A table's data tab names the table's own column types, and a query tab its result's")
        func onlyTableTabsNameDeclaredTypes() {
            let fixture = CoordinatorFixture()
            let table = fixture.addTab(QueryTab(title: "orders", query: "SELECT * FROM orders", tabType: .table, tableName: "orders"))
            let query = fixture.addTab(QueryTab(title: "Query 1", query: "SELECT id FROM orders", tabType: .query))

            #expect(fixture.coordinator.gridConfiguration(for: table).namesDeclaredColumnTypes)
            #expect(!fixture.coordinator.gridConfiguration(for: query).namesDeclaredColumnTypes)
        }
    }
}
