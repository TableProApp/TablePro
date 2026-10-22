//
//  QueryTabPinningTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct QueryTabPinningTests {
    private func makeManager(_ count: Int) -> QueryTabManager {
        let manager = QueryTabManager()
        for index in 0 ..< count {
            manager.tabs.append(QueryTab(title: "tab\(index)", query: "", tabType: .query))
        }
        manager.selectedTabId = manager.tabs.first?.id
        return manager
    }

    private func strip(_ manager: QueryTabManager) -> [String] {
        manager.visibleTabs.map(\.title)
    }

    @Test("A pinned tab moves to the front of the strip")
    func pinnedTabLeadsTheStrip() {
        let manager = makeManager(4)

        manager.setPinned(true, id: manager.tabs[2].id)

        #expect(strip(manager) == ["tab2", "tab0", "tab1", "tab3"])
        #expect(manager.isPinned(id: manager.visibleTabs[0].id))
    }

    @Test("A newly pinned tab lands after the tabs already pinned")
    func newPinJoinsTheEndOfThePins() {
        let manager = makeManager(4)
        let second = manager.tabs[1].id

        manager.setPinned(true, id: manager.tabs[3].id)
        manager.setPinned(true, id: second)

        #expect(strip(manager) == ["tab3", "tab1", "tab0", "tab2"])
    }

    @Test("An unpinned tab goes to the start of the unpinned tabs")
    func unpinnedTabLeadsTheRest() {
        let manager = makeManager(4)
        let first = manager.tabs[0].id
        let second = manager.tabs[1].id
        manager.setPinned(true, id: first)
        manager.setPinned(true, id: second)

        manager.setPinned(false, id: first)

        #expect(strip(manager) == ["tab1", "tab0", "tab2", "tab3"])
        #expect(!manager.isPinned(id: first))
    }

    /// The save on disk follows `tabStructureVersion`, and pinning the first tab reorders nothing.
    @Test("Pinning a tab that is already first still marks the tab set for saving")
    func pinningInPlaceBumpsTheStructureVersion() {
        let manager = makeManager(3)
        let version = manager.tabStructureVersion

        manager.setPinned(true, id: manager.tabs[0].id)

        #expect(manager.tabStructureVersion > version)
    }

    @Test("Pinning a preview tab keeps it open")
    func pinningPromotesAPreview() throws {
        let manager = QueryTabManager()
        try manager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "db", isPreview: true)
        let tabId = try #require(manager.selectedTabId)

        manager.setPinned(true, id: tabId)

        #expect(manager.selectedTab?.isPreview == false)
        #expect(manager.selectedTab?.isPinned == true)
    }

    @Test("A pinned tab appended at the end still shows in the pinned run")
    func appendedPinnedTabJoinsThePins() {
        let manager = makeManager(2)
        var adopted = QueryTab(title: "adopted", query: "", tabType: .query)
        adopted.isPinned = true

        manager.adoptTab(adopted)

        #expect(strip(manager) == ["adopted", "tab0", "tab1"])
    }

    @Test("Unpinning lands first among the unpinned tabs even after a pinned tab was appended")
    func unpinAfterAnAppendedPin() {
        let manager = makeManager(2)
        let first = manager.tabs[0].id
        manager.setPinned(true, id: first)
        var adopted = QueryTab(title: "adopted", query: "", tabType: .query)
        adopted.isPinned = true
        manager.adoptTab(adopted)

        manager.setPinned(false, id: first)

        #expect(strip(manager) == ["adopted", "tab0", "tab1"])
    }

    @Test("A drag of a pinned tab stops at the end of the pinned run")
    func pinnedMoveStaysAmongPins() {
        let manager = makeManager(4)
        let pinned = manager.tabs[0].id
        manager.setPinned(true, id: pinned)
        manager.setPinned(true, id: manager.tabs[1].id)

        manager.moveTab(id: pinned, to: 3)

        #expect(strip(manager) == ["tab1", "tab0", "tab2", "tab3"])
    }

    @Test("A drag of an unpinned tab stops after the pinned run")
    func unpinnedMoveStaysOutOfPins() {
        let manager = makeManager(4)
        let moving = manager.tabs[3].id
        manager.setPinned(true, id: manager.tabs[0].id)

        manager.moveTab(id: moving, to: 0)

        #expect(strip(manager) == ["tab0", "tab3", "tab1", "tab2"])
    }

    @Test("Move Tab Left and Right stop at the edge of the pinned run")
    func stepMovesStopAtTheBoundary() {
        let manager = makeManager(3)
        let pinned = manager.tabs[0].id
        manager.setPinned(true, id: pinned)
        let firstUnpinned = manager.visibleTabs[1].id

        #expect(!manager.canMoveTab(id: pinned, by: 1))
        #expect(!manager.canMoveTab(id: firstUnpinned, by: -1))
        #expect(manager.canMoveTab(id: firstUnpinned, by: 1))
    }

    @Test("Command-number counts pinned tabs first")
    func numberedSelectionFollowsTheStrip() {
        let manager = makeManager(3)
        let last = manager.tabs[2].id
        manager.setPinned(true, id: last)

        manager.selectTab(at: 0)

        #expect(manager.selectedTabId == last)
    }

    @Test("The pin survives the saved tab set")
    func pinRoundTripsThroughPersistence() throws {
        var tab = QueryTab(title: "scratch", query: "SELECT 1", tabType: .query)
        tab.isPinned = true

        let data = try JSONEncoder().encode(tab.toPersistedTab())
        let decoded = try JSONDecoder().decode(PersistedTab.self, from: data)

        #expect(QueryTab(from: decoded, defaultPageSize: 1_000).isPinned)
    }

    @Test("A tab saved before pinning existed comes back unpinned")
    func legacyTabDecodesUnpinned() throws {
        let current = try JSONEncoder().encode(QueryTab(title: "Query 1", tabType: .query).toPersistedTab())
        let parsed = try JSONSerialization.jsonObject(with: current)
        var object = try #require(parsed as? [String: Any])
        object.removeValue(forKey: "isPinned")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(PersistedTab.self, from: legacy)

        #expect(decoded.isPinned == false)
    }

    @Test("A tab moved to another connection keeps its pin")
    func pinSurvivesAConnectionMove() {
        var tab = QueryTab(title: "scratch", query: "SELECT 1", tabType: .query)
        tab.isPinned = true

        let moved = tab.movedToConnection(
            databaseName: "other",
            schemaName: nil,
            existingTabs: [],
            defaultPageSize: 1_000
        )

        #expect(moved.isPinned)
    }
}
