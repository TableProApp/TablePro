//
//  RestoredHiddenColumnsTests.swift
//  TableProTests
//
//  Hidden columns live in the per-table layout store, not in the tab record, and only the tab
//  selected at launch used to read them. Every other restored tab came back showing columns the
//  user had hidden, and its first hide wrote that near-empty set over the table's stored one.
//

import Foundation
@testable import TablePro
import Testing

@MainActor
private final class StubColumnLayoutPersister: ColumnLayoutPersisting {
    var hidden: [String: Set<String>] = [:]

    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}

    func loadHiddenColumns(for key: ColumnLayoutTableKey) -> Set<String> {
        hidden[key.tableName] ?? []
    }

    func saveHiddenColumns(_ hidden: Set<String>, for key: ColumnLayoutTableKey) {
        self.hidden[key.tableName] = hidden
    }
}

@Suite("Restored hidden columns")
@MainActor
struct RestoredHiddenColumnsTests {
    private let connectionId = UUID()

    private func tableTab(_ tableName: String) -> QueryTab {
        QueryTab(
            title: tableName,
            query: "SELECT * FROM \(tableName)",
            tabType: .table,
            tableName: tableName
        )
    }

    @Test("A restored table tab picks up the columns hidden for its table")
    func hydratesATableTab() {
        let persister = StubColumnLayoutPersister()
        persister.hidden["users"] = ["email"]
        var tabs = [tableTab("users")]

        RestoredHiddenColumns.hydrate(&tabs, connectionId: connectionId, persister: persister)

        #expect(tabs[0].columnLayout.hiddenColumns == ["email"])
    }

    /// The reported failure: three tabs, only the one in front came back correct.
    @Test("Every restored tab is hydrated, not just the first")
    func hydratesEveryTab() {
        let persister = StubColumnLayoutPersister()
        persister.hidden["users"] = ["email"]
        persister.hidden["orders"] = ["total"]
        persister.hidden["products"] = ["sku"]
        var tabs = [tableTab("users"), tableTab("orders"), tableTab("products")]

        RestoredHiddenColumns.hydrate(&tabs, connectionId: connectionId, persister: persister)

        #expect(tabs[0].columnLayout.hiddenColumns == ["email"])
        #expect(tabs[1].columnLayout.hiddenColumns == ["total"])
        #expect(tabs[2].columnLayout.hiddenColumns == ["sku"])
    }

    @Test("A tab that already carries hidden columns is left alone")
    func leavesAPopulatedTabAlone() {
        let persister = StubColumnLayoutPersister()
        persister.hidden["users"] = ["email"]
        var tabs = [tableTab("users")]
        tabs[0].columnLayout.hiddenColumns = ["notes"]

        RestoredHiddenColumns.hydrate(&tabs, connectionId: connectionId, persister: persister)

        #expect(tabs[0].columnLayout.hiddenColumns == ["notes"])
    }

    @Test("A table with nothing stored stays empty")
    func nothingStoredStaysEmpty() {
        var tabs = [tableTab("users")]

        RestoredHiddenColumns.hydrate(
            &tabs,
            connectionId: connectionId,
            persister: StubColumnLayoutPersister()
        )

        #expect(tabs[0].columnLayout.hiddenColumns.isEmpty)
    }

    @Test("A query tab is not touched")
    func skipsQueryTabs() {
        let persister = StubColumnLayoutPersister()
        persister.hidden["users"] = ["email"]
        var tabs = [QueryTab(title: "Query 1", query: "SELECT 1", tabType: .query)]

        RestoredHiddenColumns.hydrate(&tabs, connectionId: connectionId, persister: persister)

        #expect(tabs[0].columnLayout.hiddenColumns.isEmpty)
    }

    @Test("A table tab with no table name is skipped")
    func skipsATabWithoutATableName() {
        let persister = StubColumnLayoutPersister()
        persister.hidden[""] = ["email"]
        var tabs = [QueryTab(title: "untitled", query: "", tabType: .table)]

        RestoredHiddenColumns.hydrate(&tabs, connectionId: connectionId, persister: persister)

        #expect(tabs[0].columnLayout.hiddenColumns.isEmpty)
    }
}
