//
//  CoordinatorEditorLoadTests.swift
//  TableProTests
//
//  Tests for loadQueryIntoEditor() and insertQueryFromAI()
//  on MainContentCoordinator.
//

import Foundation
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
        let filterStateManager = FilterStateManager()
        let toolbarState = ConnectionToolbarState()

        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: changeManager,
            filterStateManager: filterStateManager,
            columnVisibilityManager: ColumnVisibilityManager(),
            toolbarState: toolbarState
        )
        return (coordinator, tabManager)
    }

    // MARK: - loadQueryIntoEditor

    @Test("loadQueryIntoEditor replaces query text on selected query tab")
    @MainActor
    func loadQueryReplacesQueryText() {
        let (coordinator, tabManager) = makeCoordinator()
        defer { coordinator.teardown() }

        tabManager.addTab(initialQuery: "SELECT 1")

        coordinator.loadQueryIntoEditor("SELECT * FROM users")

        #expect(tabManager.tabs[0].query == "SELECT * FROM users")
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
    func loadQuerySkipsTableTab() {
        let (coordinator, tabManager) = makeCoordinator()
        defer { coordinator.teardown() }

        tabManager.addTableTab(tableName: "users")
        let originalQuery = tabManager.tabs[0].query

        // Falls through to WindowOpener path; table tab unchanged
        coordinator.loadQueryIntoEditor("SELECT * FROM users")

        #expect(tabManager.tabs[0].tabType == .table)
        #expect(tabManager.tabs[0].query == originalQuery)
    }

    @Test("loadQueryIntoEditor does nothing when no tabs exist")
    @MainActor
    func loadQueryNoTabs() {
        let (coordinator, tabManager) = makeCoordinator()
        defer { coordinator.teardown() }

        #expect(tabManager.tabs.isEmpty)

        // Falls through to WindowOpener path; no crash
        coordinator.loadQueryIntoEditor("SELECT 1")

        #expect(tabManager.tabs.isEmpty)
    }

    // MARK: - insertQueryFromAI

    @Test("insertQueryFromAI sets query directly when tab is empty")
    @MainActor
    func insertAiSetsQueryWhenEmpty() {
        let (coordinator, tabManager) = makeCoordinator()
        defer { coordinator.teardown() }

        tabManager.addTab()
        tabManager.tabs[0].query = ""

        coordinator.insertQueryFromAI("SELECT * FROM users")

        #expect(tabManager.tabs[0].query == "SELECT * FROM users")
    }

    @Test("insertQueryFromAI appends with separator when tab has existing text")
    @MainActor
    func insertAiAppendsToExistingQuery() {
        let (coordinator, tabManager) = makeCoordinator()
        defer { coordinator.teardown() }

        tabManager.addTab(initialQuery: "SELECT 1")

        coordinator.insertQueryFromAI("SELECT 2")

        #expect(tabManager.tabs[0].query == "SELECT 1\n\nSELECT 2")
    }

    @Test("insertQueryFromAI treats whitespace-only text as empty")
    @MainActor
    func insertAiTreatsWhitespaceAsEmpty() {
        let (coordinator, tabManager) = makeCoordinator()
        defer { coordinator.teardown() }

        tabManager.addTab()
        tabManager.tabs[0].query = "   \n  \t  "

        coordinator.insertQueryFromAI("SELECT * FROM orders")

        #expect(tabManager.tabs[0].query == "SELECT * FROM orders")
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
    func insertAiSkipsTableTab() {
        let (coordinator, tabManager) = makeCoordinator()
        defer { coordinator.teardown() }

        tabManager.addTableTab(tableName: "orders")
        let originalQuery = tabManager.tabs[0].query

        coordinator.insertQueryFromAI("SELECT * FROM orders")

        #expect(tabManager.tabs[0].tabType == .table)
        #expect(tabManager.tabs[0].query == originalQuery)
    }

    @Test("insertQueryFromAI does nothing when no tabs exist")
    @MainActor
    func insertAiNoTabs() {
        let (coordinator, tabManager) = makeCoordinator()
        defer { coordinator.teardown() }

        #expect(tabManager.tabs.isEmpty)

        coordinator.insertQueryFromAI("SELECT 1")

        #expect(tabManager.tabs.isEmpty)
    }
}
