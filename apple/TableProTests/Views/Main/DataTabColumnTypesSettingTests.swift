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
        }
    }
}
