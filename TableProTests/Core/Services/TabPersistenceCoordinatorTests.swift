//
//  TabPersistenceCoordinatorTests.swift
//  TableProTests
//
//  Tests for TabPersistenceCoordinator tab state persistence.
//

import Foundation
import TableProPluginKit
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
            #expect(restored.content.query == original.content.query)
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

    @Test("Large query over 500KB is truncated to empty string in persisted tab")
    func largeQueryIsTruncated() async {
        let coordinator = makeCoordinator()
        let largeQuery = String(repeating: "A", count: 600_000)
        var tab = QueryTab(id: UUID(), title: "Big", query: largeQuery, tabType: .query)
        tab.content.query = largeQuery

        coordinator.saveNow(tabs: [tab], selectedTabId: tab.id)
        await sleep()

        let result = await coordinator.restoreFromDisk()

        #expect(result.tabs.count == 1)
        #expect(result.tabs[0].content.query == "")
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

    @Test("Preview tabs are excluded from persistence")
    func previewTabsExcludedFromPersistence() async {
        let coordinator = makeCoordinator()
        let normalTab = QueryTab(id: UUID(), title: "Normal", query: "SELECT 1", tabType: .query)
        var previewTab = QueryTab(id: UUID(), title: "Preview", query: "SELECT 2", tabType: .table, tableName: "users")
        previewTab.isPreview = true

        coordinator.saveNow(tabs: [normalTab, previewTab], selectedTabId: normalTab.id)
        await sleep()

        let result = await coordinator.restoreFromDisk()

        #expect(result.tabs.count == 1)
        #expect(result.tabs[0].id == normalTab.id)
        #expect(result.tabs[0].title == "Normal")

        coordinator.clearSavedState()
        await sleep()
    }

    @Test("All-preview tabs clears saved state")
    func allPreviewTabsClearsSavedState() async {
        let coordinator = makeCoordinator()
        let normalTab = QueryTab(id: UUID(), title: "Normal", query: "SELECT 1", tabType: .query)

        // First save a normal tab
        coordinator.saveNow(tabs: [normalTab], selectedTabId: normalTab.id)
        await sleep()

        // Now save only preview tabs — should clear state
        var previewTab = QueryTab(id: UUID(), title: "Preview", query: "SELECT 2", tabType: .table, tableName: "users")
        previewTab.isPreview = true
        coordinator.saveNow(tabs: [previewTab], selectedTabId: previewTab.id)
        await sleep()

        let result = await coordinator.restoreFromDisk()
        #expect(result.tabs.isEmpty)
        #expect(result.source == .none)
    }

    @Test("selectedTabId normalizes when selected tab is preview")
    func selectedTabIdNormalizesWhenPreview() async {
        let coordinator = makeCoordinator()
        let normalTab = QueryTab(id: UUID(), title: "Normal", query: "SELECT 1", tabType: .query)
        var previewTab = QueryTab(id: UUID(), title: "Preview", query: "SELECT 2", tabType: .table, tableName: "users")
        previewTab.isPreview = true

        // Select the preview tab — should normalize to first non-preview tab
        coordinator.saveNow(tabs: [normalTab, previewTab], selectedTabId: previewTab.id)
        await sleep()

        let result = await coordinator.restoreFromDisk()
        #expect(result.selectedTabId == normalTab.id)

        coordinator.clearSavedState()
        await sleep()
    }

    @Test("Linked-favorite tab with sourceFileURL round-trips through persistence")
    func sourceFileURLRoundTrip() async {
        let coordinator = makeCoordinator()
        let url = URL(fileURLWithPath: "/Users/test/Documents/sample.sql")
        var tab = QueryTab(id: UUID(), title: "sample", query: "SELECT 1", tabType: .query)
        tab.content.sourceFileURL = url

        coordinator.saveNow(tabs: [tab], selectedTabId: tab.id)
        await sleep()

        let result = await coordinator.restoreFromDisk()

        #expect(result.tabs.count == 1)
        #expect(result.tabs[0].content.sourceFileURL == url)
        #expect(result.tabs[0].id == tab.id)

        coordinator.clearSavedState()
        await sleep()
    }

    @Test("Three linked-favorite tabs all round-trip with distinct sourceFileURLs")
    func multipleLinkedFavoriteTabsRoundTrip() async {
        let coordinator = makeCoordinator()
        let urls = (0..<3).map { URL(fileURLWithPath: "/tmp/file-\($0).sql") }
        let tabs: [QueryTab] = urls.enumerated().map { index, url in
            var tab = QueryTab(id: UUID(), title: "file-\(index)", query: "SELECT \(index)", tabType: .query)
            tab.content.sourceFileURL = url
            return tab
        }

        coordinator.saveNow(tabs: tabs, selectedTabId: tabs[1].id)
        await sleep()

        let result = await coordinator.restoreFromDisk()

        #expect(result.tabs.count == 3)
        #expect(result.selectedTabId == tabs[1].id)
        for (original, restored) in zip(tabs, result.tabs) {
            #expect(restored.id == original.id)
            #expect(restored.content.sourceFileURL == original.content.sourceFileURL)
        }

        coordinator.clearSavedState()
        await sleep()
    }

    @Test("Tab properties preserved: tableName, isView, databaseName")
    func tabPropertiesPreserved() async {
        let coordinator = makeCoordinator()

        var tab = QueryTab(id: UUID(), title: "users", query: "SELECT * FROM users", tabType: .table, tableName: "users")
        tab.tableContext.isView = true
        tab.tableContext.databaseName = "production"

        coordinator.saveNow(tabs: [tab], selectedTabId: tab.id)
        await sleep()

        let result = await coordinator.restoreFromDisk()

        #expect(result.tabs.count == 1)
        let restored = result.tabs[0]
        #expect(restored.tableContext.tableName == "users")
        #expect(restored.tableContext.isView == true)
        #expect(restored.tableContext.databaseName == "production")
        #expect(restored.id == tab.id)
        #expect(restored.tabType == .table)

        coordinator.clearSavedState()
        await sleep()
    }
}
