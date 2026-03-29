//
//  SessionStateFactoryTests.swift
//  TableProTests
//
//  Tests for SessionStateFactory, validating session state creation logic
//  extracted from MainContentView.init.
//

import Foundation
@testable import TablePro
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
        showStructure: Bool = false
    ) -> EditorTabPayload {
        EditorTabPayload(
            connectionId: connectionId,
            tabType: tabType,
            tableName: tableName,
            databaseName: databaseName,
            initialQuery: initialQuery,
            isView: isView,
            showStructure: showStructure
        )
    }

    // MARK: - Tests

    @Test("Payload with tableName creates a table tab")
    @MainActor
    func payloadWithTableName_createsTableTab() {
        let conn = TestFixtures.makeConnection()
        let payload = makePayload(
            connectionId: conn.id,
            tabType: .table,
            tableName: "users"
        )

        let state = SessionStateFactory.create(connection: conn, payload: payload)

        #expect(state.tabManager.tabs.count == 1)
        #expect(state.tabManager.tabs.first?.tableName == "users")
        #expect(state.tabManager.tabs.first?.tabType == .table)
    }

    @Test("Payload with initialQuery creates a query tab with that text")
    @MainActor
    func payloadWithQuery_createsQueryTab() {
        let conn = TestFixtures.makeConnection()
        let query = "SELECT * FROM orders"
        let payload = makePayload(
            connectionId: conn.id,
            tabType: .query,
            initialQuery: query
        )

        let state = SessionStateFactory.create(connection: conn, payload: payload)

        #expect(state.tabManager.tabs.count == 1)
        #expect(state.tabManager.tabs.first?.query == query)
        #expect(state.tabManager.tabs.first?.tabType == .query)
    }

    @Test("Payload with showStructure sets showStructure on the tab")
    @MainActor
    func payloadWithStructure_setsShowStructure() {
        let conn = TestFixtures.makeConnection()
        let payload = makePayload(
            connectionId: conn.id,
            tabType: .table,
            tableName: "users",
            showStructure: true
        )

        let state = SessionStateFactory.create(connection: conn, payload: payload)

        guard let tab = state.tabManager.tabs.first else {
            Issue.record("Expected at least one tab")
            return
        }
        #expect(tab.showStructure == true)
    }

    @Test("Payload with isView sets isView and clears isEditable")
    @MainActor
    func payloadWithView_setsIsViewAndNotEditable() {
        let conn = TestFixtures.makeConnection()
        let payload = makePayload(
            connectionId: conn.id,
            tabType: .table,
            tableName: "user_view",
            isView: true
        )

        let state = SessionStateFactory.create(connection: conn, payload: payload)

        guard let tab = state.tabManager.tabs.first else {
            Issue.record("Expected at least one tab")
            return
        }
        #expect(tab.isView == true)
        #expect(tab.isEditable == false)
    }

    @Test("Nil payload creates empty tab manager")
    @MainActor
    func nilPayload_createsEmptyTabManager() {
        let conn = TestFixtures.makeConnection()

        let state = SessionStateFactory.create(connection: conn, payload: nil)

        #expect(state.tabManager.tabs.isEmpty)
    }

    @Test("Connection-only payload without isNewTab creates empty tab manager")
    @MainActor
    func connectionOnlyPayload_createsEmptyTabManager() {
        let conn = TestFixtures.makeConnection()
        let payload = makePayload(connectionId: conn.id, tabType: .query)

        let state = SessionStateFactory.create(connection: conn, payload: payload)

        #expect(state.tabManager.tabs.isEmpty)
    }

    @Test("Connection-only payload with isNewTab creates a default query tab")
    @MainActor
    func connectionOnlyPayload_isNewTab_createsDefaultTab() {
        let conn = TestFixtures.makeConnection()
        let payload = EditorTabPayload(connectionId: conn.id, tabType: .query, isNewTab: true)

        let state = SessionStateFactory.create(connection: conn, payload: payload)

        #expect(state.tabManager.tabs.count == 1)
        #expect(state.tabManager.tabs.first?.tabType == .query)
    }

    @Test("Factory is idempotent: two calls produce fresh but equivalent instances")
    @MainActor
    func factoryIsIdempotent() {
        let conn = TestFixtures.makeConnection()
        let payload = makePayload(
            connectionId: conn.id,
            tabType: .table,
            tableName: "products"
        )

        let state1 = SessionStateFactory.create(connection: conn, payload: payload)
        let state2 = SessionStateFactory.create(connection: conn, payload: payload)

        // Different instances
        #expect(state1.tabManager !== state2.tabManager)
        #expect(state1.coordinator !== state2.coordinator)

        // Equivalent content
        #expect(state1.tabManager.tabs.count == state2.tabManager.tabs.count)
        #expect(state1.tabManager.tabs.first?.tableName == state2.tabManager.tabs.first?.tableName)
    }

    @Test("Coordinator receives the factory's tabManager")
    @MainActor
    func coordinatorReceivesCorrectDependencies() {
        let conn = TestFixtures.makeConnection()
        let payload = makePayload(
            connectionId: conn.id,
            tabType: .table,
            tableName: "items"
        )

        let state = SessionStateFactory.create(connection: conn, payload: payload)

        #expect(state.coordinator.tabManager === state.tabManager)
    }
}
