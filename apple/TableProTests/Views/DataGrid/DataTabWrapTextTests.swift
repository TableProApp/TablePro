//
//  DataTabWrapTextTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

extension GlobalStateSuites {
    @Suite(.appSettings { $0.dataGrid.wrapText = true })
    @MainActor
    struct DataTabWrapTextTests {
        @Test("A new tab takes the Wrap text in cells setting, and a later change of the setting leaves it alone")
        func newTabTakesTheSetting() throws {
            let manager = QueryTabManager()
            manager.addTab()
            let first = try #require(manager.tabs.last)
            #expect(first.wrapsText)

            AppSettingsManager.shared.dataGrid.wrapText = false
            #expect(manager.tabs.first { $0.id == first.id }?.wrapsText == true)

            manager.addTab()
            #expect(manager.tabs.last?.wrapsText == false)
        }

        @Test("The data tab's store reads and writes the tab's flag")
        func storeIsBackedByTheTab() throws {
            let fixture = CoordinatorFixture()
            var tab = QueryTab(title: "Query 1", tabType: .query)
            tab.wrapsText = false
            fixture.addTab(tab)
            let store = QueryTabGridStateStore(tabId: tab.id, coordinator: fixture.coordinator)
            #expect(!store.wrapsText)

            store.wrapsText = true

            #expect(fixture.tabManager.tabs.first { $0.id == tab.id }?.wrapsText == true)
            #expect(store.wrapsText)
        }

        @Test("The data tab's grid offers Wrap Text, and toggling it clears the text formatted for the other mode")
        func dataTabGridOffersWrapText() throws {
            let fixture = CoordinatorFixture()
            var tab = QueryTab(title: "Query 1", tabType: .query)
            tab.wrapsText = false
            fixture.addTab(tab)
            let model = fixture.coordinator.gridModel(forTab: tab.id)
            #expect(model.configuration.commands.contains(.wrapText))
            model.display.cache.setBox(RowDisplayBox(["0"]), forID: .existing(0))

            model.setWrapsText(true)

            #expect(model.wrapsText)
            #expect(model.display.keepsLineBreaks)
            #expect(model.display.cache.box(forID: .existing(0)) == nil)
            #expect(fixture.tabManager.tabs.first { $0.id == tab.id }?.wrapsText == true)
        }
    }
}
