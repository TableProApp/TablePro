//
//  TabSessionTests.swift
//  TableProTests
//
//  TabSession holds a tab's row buffer and nothing else. It used to mirror most of QueryTab too,
//  which no reader consulted and no retarget updated (#2060).
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("TabSession")
@MainActor
struct TabSessionTests {
    @Test("A new session starts empty")
    func newSessionStartsEmpty() {
        let session = TabSession()

        #expect(session.tableRows.rows.isEmpty)
        #expect(session.tableRows.columns.isEmpty)
        #expect(session.isEvicted == false)
        #expect(session.dataRevision == 0)
    }

    @Test("A session keeps the id it was created with")
    func sessionKeepsItsId() {
        let id = UUID()

        #expect(TabSession(id: id).id == id)
    }

    /// The row buffer lives here precisely because it is a reference: mutating it must not copy
    /// the tab or re-render the editor.
    @Test("Every holder of a session sees the same rows")
    func sessionIsShared() {
        let session = TabSession()
        let alias = session

        alias.tableRows = TableRows(columns: ["id"])

        #expect(session.tableRows.columns == ["id"])
    }
}

/// The point of #2060: pointing a tab at another table is not an insert or a removal, so the
/// registry never reconciled the session. Nothing per-table may live in the session for that to
/// matter, and the tab itself has to be the one thing that describes the table.
@Suite("Tab retarget leaves no stale per-tab state")
@MainActor
struct TabRetargetSessionStateTests {
    @Test("Retargeting a tab reuses its session rather than replacing it")
    func retargetKeepsTheSameSession() throws {
        let (tabManager, registry) = Self.makeManager()
        let tabId = Self.addTableTab(to: tabManager, tableName: "orders")
        let before = try #require(registry.session(for: tabId))

        try tabManager.replaceTabContent(tableName: "customers")

        let after = try #require(registry.session(for: tabId))
        #expect(after === before)
    }

    @Test("Retargeting a tab moves every table-scoped field on the tab itself")
    func retargetUpdatesTheTab() throws {
        let (tabManager, _) = Self.makeManager()
        let tabId = Self.addTableTab(to: tabManager, tableName: "orders")

        try tabManager.replaceTabContent(tableName: "customers")

        let tab = try #require(tabManager.tabs.first(where: { $0.id == tabId }))
        #expect(tab.tableContext.tableName == "customers")
        #expect(tab.content.query.contains("customers"))
        #expect(tab.title.contains("customers"))
        #expect(tab.sortState.isSorting == false)
        #expect(tab.filterState.hasAppliedFilters == false)
        #expect(tab.columnLayout.hiddenColumns.isEmpty)
    }

    @Test("The row buffer stays reachable through the retarget")
    func rowBufferSurvivesTheRetarget() throws {
        let (tabManager, registry) = Self.makeManager()
        let tabId = Self.addTableTab(to: tabManager, tableName: "orders")
        registry.setTableRows(TableRows(columns: ["id"]), for: tabId)

        try tabManager.replaceTabContent(tableName: "customers")

        #expect(registry.tableRows(for: tabId).columns == ["id"])
    }

    private static func makeManager() -> (QueryTabManager, TabSessionRegistry) {
        let tabManager = QueryTabManager()
        let registry = TabSessionRegistry()
        tabManager.bindTabSessionRegistry(registry)
        return (tabManager, registry)
    }

    private static func addTableTab(to tabManager: QueryTabManager, tableName: String) -> UUID {
        let tab = QueryTab(
            title: tableName,
            query: "SELECT * FROM \(tableName)",
            tabType: .table,
            tableName: tableName
        )
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
        return tab.id
    }
}
