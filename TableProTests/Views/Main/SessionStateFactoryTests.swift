//
//  SessionStateFactoryTests.swift
//  TableProTests
//
//  Tests for SessionStateFactory session-state creation and
//  MainContentCoordinator.handleNewTabIntent payload routing.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("SessionStateFactory")
struct SessionStateFactoryTests {
    // MARK: - Helpers

    private func makePayload(
        connectionId: UUID = UUID(),
        tabType: TabType = .query,
        tableName: String? = nil,
        databaseName: String? = nil,
        initialQuery: String? = nil,
        isView: Bool = false,
        showStructure: Bool = false,
        intent: TabIntent = .openContent
    ) -> EditorTabPayload {
        EditorTabPayload(
            connectionId: connectionId,
            tabType: tabType,
            tableName: tableName,
            databaseName: databaseName,
            initialQuery: initialQuery,
            isView: isView,
            showStructure: showStructure,
            intent: intent
        )
    }

    // MARK: - Factory

    @Test("create produces an empty tab manager")
    @MainActor
    func createProducesEmptyTabManager() {
        let conn = TestFixtures.makeConnection()

        let state = SessionStateFactory.create(connection: conn)

        #expect(state.tabManager.tabs.isEmpty)
    }

    @Test("create wires the coordinator to the factory's tab manager")
    @MainActor
    func coordinatorReceivesCorrectDependencies() {
        let conn = TestFixtures.makeConnection()

        let state = SessionStateFactory.create(connection: conn)

        #expect(state.coordinator.tabManager === state.tabManager)
    }

    @Test("create is idempotent: two calls produce fresh instances")
    @MainActor
    func factoryIsIdempotent() {
        let conn = TestFixtures.makeConnection()

        let state1 = SessionStateFactory.create(connection: conn)
        let state2 = SessionStateFactory.create(connection: conn)

        #expect(state1.tabManager !== state2.tabManager)
        #expect(state1.coordinator !== state2.coordinator)
    }

    // MARK: - handleNewTabIntent

    @Test("Payload with tableName adds a table tab")
    @MainActor
    func payloadWithTableName_addsTableTab() {
        let conn = TestFixtures.makeConnection()
        let state = SessionStateFactory.create(connection: conn)

        state.coordinator.handleNewTabIntent(
            makePayload(connectionId: conn.id, tabType: .table, tableName: "users")
        )

        #expect(state.tabManager.tabs.count == 1)
        #expect(state.tabManager.tabs.first?.tableContext.tableName == "users")
        #expect(state.tabManager.tabs.first?.tabType == .table)
    }

    @Test("Payload with initialQuery adds a query tab with that text")
    @MainActor
    func payloadWithQuery_addsQueryTab() {
        let conn = TestFixtures.makeConnection()
        let state = SessionStateFactory.create(connection: conn)
        let query = "SELECT * FROM orders"

        state.coordinator.handleNewTabIntent(
            makePayload(connectionId: conn.id, tabType: .query, initialQuery: query)
        )

        #expect(state.tabManager.tabs.count == 1)
        #expect(state.tabManager.tabs.first?.content.query == query)
        #expect(state.tabManager.tabs.first?.tabType == .query)
    }

    @Test("Payload with showStructure sets structure view mode on the tab")
    @MainActor
    func payloadWithStructure_setsShowStructure() {
        let conn = TestFixtures.makeConnection()
        let state = SessionStateFactory.create(connection: conn)

        state.coordinator.handleNewTabIntent(
            makePayload(connectionId: conn.id, tabType: .table, tableName: "users", showStructure: true)
        )

        guard let tab = state.tabManager.tabs.first else {
            Issue.record("Expected at least one tab")
            return
        }
        #expect(tab.display.resultsViewMode == .structure)
    }

    @Test("Payload with isView sets isView and clears isEditable")
    @MainActor
    func payloadWithView_setsIsViewAndNotEditable() {
        let conn = TestFixtures.makeConnection()
        let state = SessionStateFactory.create(connection: conn)

        state.coordinator.handleNewTabIntent(
            makePayload(connectionId: conn.id, tabType: .table, tableName: "user_view", isView: true)
        )

        guard let tab = state.tabManager.tabs.first else {
            Issue.record("Expected at least one tab")
            return
        }
        #expect(tab.tableContext.isView == true)
        #expect(tab.tableContext.isEditable == false)
    }

    @Test("openContent query payload with no content is a no-op")
    @MainActor
    func openContentQueryWithoutContent_isNoOp() {
        let conn = TestFixtures.makeConnection()
        let state = SessionStateFactory.create(connection: conn)

        state.coordinator.handleNewTabIntent(
            makePayload(connectionId: conn.id, tabType: .query)
        )

        #expect(state.tabManager.tabs.isEmpty)
    }

    @Test("newEmptyTab intent adds a default query tab")
    @MainActor
    func newEmptyTabIntent_addsDefaultQueryTab() {
        let conn = TestFixtures.makeConnection()
        let state = SessionStateFactory.create(connection: conn)

        state.coordinator.handleNewTabIntent(
            EditorTabPayload(connectionId: conn.id, tabType: .query, intent: .newEmptyTab)
        )

        #expect(state.tabManager.tabs.count == 1)
        #expect(state.tabManager.tabs.first?.tabType == .query)
    }
}
