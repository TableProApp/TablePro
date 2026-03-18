//
//  TabDiskActorTests.swift
//  TableProTests
//
//  Tests for TabDiskActor tab state persistence.
//

import Foundation
@testable import TablePro
import Testing

@Suite("TabDiskActor")
struct TabDiskActorTests {
    private let actor = TabDiskActor.shared

    private func makeTab(
        id: UUID = UUID(),
        title: String = "Test Tab",
        query: String = "SELECT 1",
        tabType: TabType = .query,
        tableName: String? = nil,
        isView: Bool = false,
        databaseName: String = ""
    ) -> PersistedTab {
        PersistedTab(
            id: id,
            title: title,
            query: query,
            tabType: tabType,
            tableName: tableName,
            isView: isView,
            databaseName: databaseName
        )
    }

    // MARK: - save / load round-trip

    @Test("Save then load round-trips correctly")
    func saveAndLoadRoundTrip() async {
        let connectionId = UUID()
        let tabId = UUID()
        let tab = makeTab(id: tabId, title: "My Tab", query: "SELECT * FROM users")

        await actor.save(connectionId: connectionId, tabs: [tab], selectedTabId: tabId)
        let state = await actor.load(connectionId: connectionId)

        #expect(state != nil)
        #expect(state?.tabs.count == 1)
        #expect(state?.tabs.first?.id == tabId)
        #expect(state?.tabs.first?.title == "My Tab")
        #expect(state?.tabs.first?.query == "SELECT * FROM users")
        #expect(state?.tabs.first?.tabType == .query)
        #expect(state?.selectedTabId == tabId)

        await actor.clear(connectionId: connectionId)
    }

    // MARK: - load returns nil for unknown connectionId

    @Test("Load returns nil for unknown connectionId")
    func loadReturnsNilForUnknown() async {
        let result = await actor.load(connectionId: UUID())
        #expect(result == nil)
    }

    // MARK: - save overwrites previous state

    @Test("Save overwrites previous state")
    func saveOverwritesPreviousState() async {
        let connectionId = UUID()
        let tab1 = makeTab(title: "First")
        let tab2 = makeTab(title: "Second")

        await actor.save(connectionId: connectionId, tabs: [tab1], selectedTabId: tab1.id)
        await actor.save(connectionId: connectionId, tabs: [tab2], selectedTabId: tab2.id)

        let state = await actor.load(connectionId: connectionId)

        #expect(state?.tabs.count == 1)
        #expect(state?.tabs.first?.title == "Second")
        #expect(state?.selectedTabId == tab2.id)

        await actor.clear(connectionId: connectionId)
    }

    // MARK: - clear removes saved state

    @Test("Clear removes saved state")
    func clearRemovesSavedState() async {
        let connectionId = UUID()
        let tab = makeTab()

        await actor.save(connectionId: connectionId, tabs: [tab], selectedTabId: tab.id)
        await actor.clear(connectionId: connectionId)

        let state = await actor.load(connectionId: connectionId)
        #expect(state == nil)
    }

    // MARK: - clear on non-existent connectionId does not crash

    @Test("Clear on non-existent connectionId does not crash")
    func clearNonExistentDoesNotCrash() async {
        await actor.clear(connectionId: UUID())
    }

    // MARK: - Multiple connections are independent

    @Test("Multiple connections are independent")
    func multipleConnectionsAreIndependent() async {
        let connA = UUID()
        let connB = UUID()
        let tabA = makeTab(title: "Tab A")
        let tabB = makeTab(title: "Tab B")

        await actor.save(connectionId: connA, tabs: [tabA], selectedTabId: tabA.id)
        await actor.save(connectionId: connB, tabs: [tabB], selectedTabId: tabB.id)

        let stateA = await actor.load(connectionId: connA)
        let stateB = await actor.load(connectionId: connB)

        #expect(stateA?.tabs.first?.title == "Tab A")
        #expect(stateB?.tabs.first?.title == "Tab B")

        await actor.clear(connectionId: connA)
        let stateAAfterClear = await actor.load(connectionId: connA)
        let stateBAfterClear = await actor.load(connectionId: connB)

        #expect(stateAAfterClear == nil)
        #expect(stateBAfterClear?.tabs.first?.title == "Tab B")

        await actor.clear(connectionId: connB)
    }

    // MARK: - selectedTabId preservation

    @Test("selectedTabId is preserved correctly including nil")
    func selectedTabIdPreserved() async {
        let connectionId = UUID()
        let tab = makeTab()

        await actor.save(connectionId: connectionId, tabs: [tab], selectedTabId: nil)
        let stateNil = await actor.load(connectionId: connectionId)
        #expect(stateNil?.selectedTabId == nil)
        #expect(stateNil?.tabs.count == 1)

        let specificId = UUID()
        let tab2 = makeTab(id: specificId)
        await actor.save(connectionId: connectionId, tabs: [tab2], selectedTabId: specificId)
        let stateWithId = await actor.load(connectionId: connectionId)
        #expect(stateWithId?.selectedTabId == specificId)

        await actor.clear(connectionId: connectionId)
    }

    // MARK: - saveLastQuery / loadLastQuery round-trip

    @Test("saveLastQuery then loadLastQuery round-trips")
    func lastQueryRoundTrip() async {
        let connectionId = UUID()
        let query = "SELECT * FROM products WHERE active = true"

        await actor.saveLastQuery(query, for: connectionId)
        let loaded = await actor.loadLastQuery(for: connectionId)

        #expect(loaded == query)

        await actor.saveLastQuery("", for: connectionId)
    }

    // MARK: - loadLastQuery returns nil for unknown connectionId

    @Test("loadLastQuery returns nil for unknown connectionId")
    func loadLastQueryReturnsNilForUnknown() async {
        let result = await actor.loadLastQuery(for: UUID())
        #expect(result == nil)
    }

    // MARK: - saveLastQuery with empty string removes the file

    @Test("saveLastQuery with empty string removes the file")
    func saveLastQueryEmptyRemovesFile() async {
        let connectionId = UUID()

        await actor.saveLastQuery("SELECT 1", for: connectionId)
        #expect(await actor.loadLastQuery(for: connectionId) != nil)

        await actor.saveLastQuery("", for: connectionId)
        let result = await actor.loadLastQuery(for: connectionId)
        #expect(result == nil)
    }

    // MARK: - saveLastQuery with whitespace-only string removes the file

    @Test("saveLastQuery with whitespace-only string removes the file")
    func saveLastQueryWhitespaceOnlyRemovesFile() async {
        let connectionId = UUID()

        await actor.saveLastQuery("SELECT 1", for: connectionId)
        await actor.saveLastQuery("   \n\t  ", for: connectionId)

        let result = await actor.loadLastQuery(for: connectionId)
        #expect(result == nil)
    }

    // MARK: - saveLastQuery skips queries exceeding 500KB

    @Test("saveLastQuery skips queries exceeding 500KB")
    func saveLastQuerySkipsLargeQueries() async {
        let connectionId = UUID()
        let smallQuery = "SELECT 1"

        await actor.saveLastQuery(smallQuery, for: connectionId)
        #expect(await actor.loadLastQuery(for: connectionId) == smallQuery)

        let largeQuery = String(repeating: "A", count: 500_001)
        await actor.saveLastQuery(largeQuery, for: connectionId)

        let result = await actor.loadLastQuery(for: connectionId)
        #expect(result == smallQuery)

        await actor.saveLastQuery("", for: connectionId)
    }

    // MARK: - Tab with all fields round-trips

    @Test("Tab with all fields including isView and databaseName round-trips")
    func tabWithAllFieldsRoundTrips() async {
        let connectionId = UUID()
        let tabId = UUID()
        let tab = makeTab(
            id: tabId,
            title: "users_view",
            query: "SELECT * FROM users_view",
            tabType: .table,
            tableName: "users_view",
            isView: true,
            databaseName: "production"
        )

        await actor.save(connectionId: connectionId, tabs: [tab], selectedTabId: tabId)
        let state = await actor.load(connectionId: connectionId)

        #expect(state != nil)
        let loaded = state?.tabs.first
        #expect(loaded?.id == tabId)
        #expect(loaded?.title == "users_view")
        #expect(loaded?.query == "SELECT * FROM users_view")
        #expect(loaded?.tabType == .table)
        #expect(loaded?.tableName == "users_view")
        #expect(loaded?.isView == true)
        #expect(loaded?.databaseName == "production")

        await actor.clear(connectionId: connectionId)
    }

    // MARK: - Multiple tabs in single save

    @Test("Multiple tabs in a single save round-trip correctly")
    func multipleTabsRoundTrip() async {
        let connectionId = UUID()
        let tab1 = makeTab(title: "Tab 1", tabType: .query)
        let tab2 = makeTab(title: "Tab 2", tabType: .table, tableName: "orders")
        let tab3 = makeTab(title: "Tab 3", tabType: .query)

        await actor.save(connectionId: connectionId, tabs: [tab1, tab2, tab3], selectedTabId: tab2.id)
        let state = await actor.load(connectionId: connectionId)

        #expect(state?.tabs.count == 3)
        #expect(state?.tabs[0].title == "Tab 1")
        #expect(state?.tabs[1].title == "Tab 2")
        #expect(state?.tabs[2].title == "Tab 3")
        #expect(state?.selectedTabId == tab2.id)

        await actor.clear(connectionId: connectionId)
    }

    // MARK: - saveSync writes data readable by load

    @Test("saveSync writes data that load can read back")
    func saveSyncWritesReadableData() async {
        let connectionId = UUID()
        let tabId = UUID()
        let tab = makeTab(id: tabId, title: "Sync Tab", query: "SELECT 42", tabType: .table, tableName: "orders")

        TabDiskActor.saveSync(connectionId: connectionId, tabs: [tab], selectedTabId: tabId)

        let state = await actor.load(connectionId: connectionId)

        #expect(state != nil)
        #expect(state?.tabs.count == 1)
        #expect(state?.tabs.first?.id == tabId)
        #expect(state?.tabs.first?.title == "Sync Tab")
        #expect(state?.tabs.first?.query == "SELECT 42")
        #expect(state?.tabs.first?.tableName == "orders")
        #expect(state?.selectedTabId == tabId)

        await actor.clear(connectionId: connectionId)
    }

    // MARK: - Empty tabs array

    @Test("Saving empty tabs array round-trips")
    func emptyTabsArrayRoundTrips() async {
        let connectionId = UUID()

        await actor.save(connectionId: connectionId, tabs: [], selectedTabId: nil)
        let state = await actor.load(connectionId: connectionId)

        #expect(state != nil)
        #expect(state?.tabs.isEmpty == true)
        #expect(state?.selectedTabId == nil)

        await actor.clear(connectionId: connectionId)
    }
}
