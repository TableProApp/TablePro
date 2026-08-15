//
//  CoordinatorEditorLoadTests.swift
//  TableProTests
//
//  Tests for loadQueryIntoEditor() and insertQueryFromAI()
//  on MainContentCoordinator.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("CoordinatorEditorLoad")
struct CoordinatorEditorLoadTests {
    // MARK: - Helpers

    @MainActor
    private func makeCoordinator() -> (MainContentCoordinator, QueryTabManager) {
        let connection = TestFixtures.makeConnection(database: "testdb")
        let tabManager = QueryTabManager()
        let changeManager = DataChangeManager()
        let toolbarState = ConnectionToolbarState()

        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: changeManager,
            toolbarState: toolbarState
        )
        coordinator.openTabInNewWindow = { _ in }
        return (coordinator, tabManager)
    }

    // MARK: - loadQueryIntoEditor

    @Test("loadQueryIntoEditor replaces query text on selected query tab")
    @MainActor
    func loadQueryReplacesQueryText() {
        let (coordinator, tabManager) = makeCoordinator()
        defer { coordinator.teardown() }

        tabManager.addTab(initialQuery: "SELECT 1")

        let disposition = coordinator.loadQueryIntoEditor("SELECT * FROM users")

        #expect(tabManager.tabs[0].content.query == "SELECT * FROM users")
        #expect(disposition == .currentCoordinator)
    }

    @Test("loadQueryIntoEditor sets hasUserInteraction to true")
    @MainActor
    func loadQuerySetsHasUserInteraction() {
        let (coordinator, tabManager) = makeCoordinator()
        defer { coordinator.teardown() }

        // addTab() with nil initialQuery leaves hasUserInteraction false
        tabManager.addTab()
        #expect(tabManager.tabs[0].hasUserInteraction == false)

        coordinator.loadQueryIntoEditor("SELECT 1")

        #expect(tabManager.tabs[0].hasUserInteraction == true)
    }

    @Test("loadQueryIntoEditor does not modify table tab")
    @MainActor
    func loadQuerySkipsTableTab() throws {
        let (coordinator, tabManager) = makeCoordinator()
        defer { coordinator.teardown() }

        try tabManager.addTableTab(tableName: "users")
        let originalQuery = tabManager.tabs[0].content.query

        // Falls through to WindowOpener path; table tab unchanged
        coordinator.loadQueryIntoEditor("SELECT * FROM users")

        #expect(tabManager.tabs[0].tabType == .table)
        #expect(tabManager.tabs[0].content.query == originalQuery)
    }

    @Test("loadQueryIntoEditor adds a tab in place when no tabs exist")
    @MainActor
    func loadQueryNoTabs() {
        let (coordinator, tabManager) = makeCoordinator()
        defer { coordinator.teardown() }

        #expect(tabManager.tabs.isEmpty)

        coordinator.loadQueryIntoEditor("SELECT 1")

        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.tabs[0].tabType == .query)
        #expect(tabManager.tabs[0].content.query == "SELECT 1")
        #expect(tabManager.tabs[0].tableContext.databaseName == "testdb")
    }

    @Test("loadQueryIntoEditor reuses a query tab in the target database")
    @MainActor
    func loadQueryReusesMatchingDatabase() {
        let (coordinator, tabManager) = makeCoordinator()
        defer { coordinator.teardown() }

        tabManager.addTab(initialQuery: "SELECT 1", databaseName: "analytics")

        let disposition = coordinator.loadQueryIntoEditor("SELECT 2", databaseName: "analytics")

        #expect(disposition == .currentCoordinator)
        #expect(tabManager.tabs[0].content.query == "SELECT 2")
        #expect(tabManager.tabs[0].tableContext.databaseName == "analytics")
    }

    @Test("loadQueryIntoEditor does not overwrite a query tab from another database")
    @MainActor
    func loadQueryPreservesDifferentDatabase() {
        let (coordinator, tabManager) = makeCoordinator()
        defer { coordinator.teardown() }
        var openedPayload: EditorTabPayload?
        coordinator.openTabInNewWindow = { openedPayload = $0 }

        tabManager.addTab(initialQuery: "SELECT private_data", databaseName: "primary")

        let disposition = coordinator.loadQueryIntoEditor("SELECT public_data", databaseName: "analytics")

        #expect(disposition == .focusedElsewhere)
        #expect(tabManager.tabs[0].content.query == "SELECT private_data")
        #expect(tabManager.tabs[0].tableContext.databaseName == "primary")
        #expect(openedPayload?.databaseName == "analytics")
        #expect(openedPayload?.initialQuery == "SELECT public_data")
    }

    @Test("loadQueryIntoEditor keeps the current tab when a new window tab is forced")
    @MainActor
    func loadQueryForcesNewWindowTab() {
        let (coordinator, tabManager) = makeCoordinator()
        defer { coordinator.teardown() }
        var openedPayload: EditorTabPayload?
        coordinator.openTabInNewWindow = { openedPayload = $0 }

        tabManager.addTab(initialQuery: "SELECT 1", databaseName: "testdb")

        let disposition = coordinator.loadQueryIntoEditor(
            "SELECT 2",
            databaseName: "testdb",
            forceNewTab: true
        )

        #expect(disposition == .focusedElsewhere)
        #expect(tabManager.tabs[0].content.query == "SELECT 1")
        #expect(openedPayload?.databaseName == "testdb")
        #expect(openedPayload?.initialQuery == "SELECT 2")
    }

    @Test("loadQueryIntoEditor reuses a tab opened without an explicit database")
    @MainActor
    func loadQueryReusesTabWithInheritedDatabase() {
        let (coordinator, tabManager) = makeCoordinator()
        defer { coordinator.teardown() }
        var openedPayload: EditorTabPayload?
        coordinator.openTabInNewWindow = { openedPayload = $0 }

        tabManager.addTab(initialQuery: "SELECT 1")
        #expect(tabManager.tabs[0].tableContext.databaseName.isEmpty)

        let disposition = coordinator.loadQueryIntoEditor("SELECT 2", databaseName: "testdb")

        #expect(disposition == .currentCoordinator)
        #expect(tabManager.tabs[0].content.query == "SELECT 2")
        #expect(openedPayload == nil)
    }

    // MARK: - insertQueryFromAI

    @Test("insertQueryFromAI sets query directly when tab is empty")
    @MainActor
    func insertAiSetsQueryWhenEmpty() {
        let (coordinator, tabManager) = makeCoordinator()
        defer { coordinator.teardown() }

        tabManager.addTab()
        tabManager.tabs[0].content.query = ""

        coordinator.insertQueryFromAI("SELECT * FROM users")

        #expect(tabManager.tabs[0].content.query == "SELECT * FROM users")
    }

    @Test("insertQueryFromAI leaves a tab that already has text alone")
    @MainActor
    func insertAiLeavesExistingQueryIntact() {
        let (coordinator, tabManager) = makeCoordinator()
        defer { coordinator.teardown() }

        tabManager.addTab(initialQuery: "SELECT 1")

        coordinator.insertQueryFromAI("SELECT 2")

        #expect(
            tabManager.tabs[0].content.query == "SELECT 1",
            "Generated SQL opens its own tab rather than appending to what the user wrote (#1257)"
        )
    }

    @Test("insertQueryFromAI treats whitespace-only text as empty")
    @MainActor
    func insertAiTreatsWhitespaceAsEmpty() {
        let (coordinator, tabManager) = makeCoordinator()
        defer { coordinator.teardown() }

        tabManager.addTab()
        tabManager.tabs[0].content.query = "   \n  \t  "

        coordinator.insertQueryFromAI("SELECT * FROM orders")

        #expect(tabManager.tabs[0].content.query == "SELECT * FROM orders")
    }

    @Test("insertQueryFromAI sets hasUserInteraction to true")
    @MainActor
    func insertAiSetsHasUserInteraction() {
        let (coordinator, tabManager) = makeCoordinator()
        defer { coordinator.teardown() }

        tabManager.addTab()
        #expect(tabManager.tabs[0].hasUserInteraction == false)

        coordinator.insertQueryFromAI("SELECT 1")

        #expect(tabManager.tabs[0].hasUserInteraction == true)
    }

    @Test("insertQueryFromAI does not modify table tab")
    @MainActor
    func insertAiSkipsTableTab() throws {
        let (coordinator, tabManager) = makeCoordinator()
        defer { coordinator.teardown() }

        try tabManager.addTableTab(tableName: "orders")
        let originalQuery = tabManager.tabs[0].content.query

        coordinator.insertQueryFromAI("SELECT * FROM orders")

        #expect(tabManager.tabs[0].tabType == .table)
        #expect(tabManager.tabs[0].content.query == originalQuery)
    }

    @Test("insertQueryFromAI opens a query tab when none is open")
    @MainActor
    func insertAiOpensATabWhenNoneExist() {
        let (coordinator, tabManager) = makeCoordinator()
        defer { coordinator.teardown() }

        #expect(tabManager.tabs.isEmpty)

        coordinator.insertQueryFromAI("SELECT 1")

        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.tabs[0].tabType == .query)
        #expect(tabManager.tabs[0].content.query == "SELECT 1")
    }
}
