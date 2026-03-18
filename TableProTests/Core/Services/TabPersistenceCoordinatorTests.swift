//
//  TabPersistenceCoordinatorTests.swift
//  TableProTests
//
//  Tests for TabPersistenceCoordinator tab state persistence.
//

import Foundation
@testable import TablePro
import Testing

@Suite("TabPersistenceCoordinator")
@MainActor
struct TabPersistenceCoordinatorTests {
    // MARK: - Helpers

    private func makeCoordinator() -> TabPersistenceCoordinator {
        TabPersistenceCoordinator(connectionId: UUID())
    }

    private func makeTabs(count: Int) -> [QueryTab] {
        (0..<count).map { i in
            QueryTab(id: UUID(), title: "Tab \(i)", query: "SELECT \(i)", tabType: .table)
        }
    }

    private func sleep(milliseconds: Int = 200) async {
        try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
    }

    // MARK: - Tests

    @Test("restoreFromDisk returns .none source when no saved state exists")
    func restoreFromDiskReturnsNoneWhenEmpty() async {
        let coordinator = makeCoordinator()

        let result = await coordinator.restoreFromDisk()

        #expect(result.tabs.isEmpty)
        #expect(result.selectedTabId == nil)
        #expect(result.source == .none)
    }

    @Test("saveNow + restoreFromDisk round-trip preserves tabs and selectedTabId")
    func saveNowAndRestoreRoundTrip() async {
        let coordinator = makeCoordinator()
        let tabs = makeTabs(count: 3)
        let selectedId = tabs[1].id

        coordinator.saveNow(tabs: tabs, selectedTabId: selectedId)
        await sleep()

        let result = await coordinator.restoreFromDisk()

        #expect(result.tabs.count == 3)
        #expect(result.selectedTabId == selectedId)
        #expect(result.source == .disk)

        for (original, restored) in zip(tabs, result.tabs) {
            #expect(restored.id == original.id)
            #expect(restored.title == original.title)
            #expect(restored.query == original.query)
            #expect(restored.tabType == original.tabType)
        }

        coordinator.clearSavedState()
        await sleep()
    }

    @Test("clearSavedState + restoreFromDisk returns empty")
    func clearSavedStateThenRestoreReturnsEmpty() async {
        let coordinator = makeCoordinator()
        let tabs = makeTabs(count: 2)

        coordinator.saveNow(tabs: tabs, selectedTabId: tabs[0].id)
        await sleep()

        coordinator.clearSavedState()
        await sleep()

        let result = await coordinator.restoreFromDisk()

        #expect(result.tabs.isEmpty)
        #expect(result.selectedTabId == nil)
        #expect(result.source == .none)
    }

    @Test("saveNowSync + restoreFromDisk round-trip works for synchronous save path")
    func saveNowSyncAndRestoreRoundTrip() async {
        let coordinator = makeCoordinator()
        let tabs = makeTabs(count: 2)
        let selectedId = tabs[0].id

        coordinator.saveNowSync(tabs: tabs, selectedTabId: selectedId)

        let result = await coordinator.restoreFromDisk()

        #expect(result.tabs.count == 2)
        #expect(result.selectedTabId == selectedId)
        #expect(result.source == .disk)

        coordinator.clearSavedState()
        await sleep()
    }

    @Test("saveNow with pre-converted PersistedTab array round-trips")
    func saveNowWithPersistedTabsRoundTrips() async {
        let coordinator = makeCoordinator()
        let persistedTabs = [
            PersistedTab(id: UUID(), title: "P1", query: "SELECT 1", tabType: .query, tableName: nil),
            PersistedTab(id: UUID(), title: "P2", query: "SELECT 2", tabType: .table, tableName: "users")
        ]
        let selectedId = persistedTabs[0].id

        coordinator.saveNow(persistedTabs: persistedTabs, selectedTabId: selectedId)
        await sleep()

        let result = await coordinator.restoreFromDisk()

        #expect(result.tabs.count == 2)
        #expect(result.selectedTabId == selectedId)
        #expect(result.tabs[0].title == "P1")
        #expect(result.tabs[1].tableName == "users")
        #expect(result.source == .disk)

        coordinator.clearSavedState()
        await sleep()
    }

    @Test("saveLastQuery + loadLastQuery round-trip")
    func saveAndLoadLastQueryRoundTrip() async {
        let coordinator = makeCoordinator()
        let query = "SELECT * FROM products WHERE active = 1"

        coordinator.saveLastQuery(query)
        await sleep()

        let loaded = await coordinator.loadLastQuery()

        #expect(loaded == query)

        coordinator.clearSavedState()
        await sleep()
    }

    @Test("loadLastQuery returns nil when nothing saved")
    func loadLastQueryReturnsNilWhenEmpty() async {
        let coordinator = makeCoordinator()

        let loaded = await coordinator.loadLastQuery()

        #expect(loaded == nil)
    }

    @Test("Large query over 500KB is truncated to empty string in persisted tab")
    func largeQueryIsTruncated() async {
        let coordinator = makeCoordinator()
        let largeQuery = String(repeating: "A", count: 600_000)
        var tab = QueryTab(id: UUID(), title: "Big", query: largeQuery, tabType: .query)
        tab.query = largeQuery

        coordinator.saveNow(tabs: [tab], selectedTabId: tab.id)
        await sleep()

        let result = await coordinator.restoreFromDisk()

        #expect(result.tabs.count == 1)
        #expect(result.tabs[0].query == "")
        #expect(result.tabs[0].title == "Big")

        coordinator.clearSavedState()
        await sleep()
    }

    @Test("restoreFromDisk returns .disk source when state exists")
    func restoreFromDiskReturnsDiskSource() async {
        let coordinator = makeCoordinator()
        let tabs = makeTabs(count: 1)

        coordinator.saveNow(tabs: tabs, selectedTabId: nil)
        await sleep()

        let result = await coordinator.restoreFromDisk()

        #expect(result.source == .disk)

        coordinator.clearSavedState()
        await sleep()
    }

    @Test("Multiple saves -- last save wins")
    func multipleSavesLastWins() async {
        let coordinator = makeCoordinator()
        let firstTabs = makeTabs(count: 1)
        let secondTabs = makeTabs(count: 3)
        let selectedId = secondTabs[2].id

        coordinator.saveNow(tabs: firstTabs, selectedTabId: firstTabs[0].id)
        await sleep()

        coordinator.saveNow(tabs: secondTabs, selectedTabId: selectedId)
        await sleep()

        let result = await coordinator.restoreFromDisk()

        #expect(result.tabs.count == 3)
        #expect(result.selectedTabId == selectedId)

        for (original, restored) in zip(secondTabs, result.tabs) {
            #expect(restored.id == original.id)
        }

        coordinator.clearSavedState()
        await sleep()
    }

    @Test("clearSavedState after saveNow clears state")
    func clearAfterSave() async {
        let coordinator = makeCoordinator()
        let tabs = makeTabs(count: 2)

        coordinator.saveNow(tabs: tabs, selectedTabId: tabs[0].id)
        await sleep()

        // Verify state exists
        let beforeClear = await coordinator.restoreFromDisk()
        #expect(beforeClear.tabs.count == 2)

        coordinator.clearSavedState()
        await sleep()

        let afterClear = await coordinator.restoreFromDisk()
        #expect(afterClear.tabs.isEmpty)
        #expect(afterClear.source == .none)
    }

    @Test("Tab properties preserved: tableName, isView, databaseName")
    func tabPropertiesPreserved() async {
        let coordinator = makeCoordinator()

        var tab = QueryTab(id: UUID(), title: "users", query: "SELECT * FROM users", tabType: .table, tableName: "users")
        tab.isView = true
        tab.databaseName = "production"

        coordinator.saveNow(tabs: [tab], selectedTabId: tab.id)
        await sleep()

        let result = await coordinator.restoreFromDisk()

        #expect(result.tabs.count == 1)
        let restored = result.tabs[0]
        #expect(restored.tableName == "users")
        #expect(restored.isView == true)
        #expect(restored.databaseName == "production")
        #expect(restored.id == tab.id)
        #expect(restored.tabType == .table)

        coordinator.clearSavedState()
        await sleep()
    }
}
