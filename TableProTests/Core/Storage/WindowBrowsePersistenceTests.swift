//
//  WindowBrowsePersistenceTests.swift
//  TableProTests
//
//  Tab state used to keep one browse container for a whole connection, so two windows saved on
//  different databases both came back on whichever one was written last. These pin the per-group
//  container down at both seams: what a save writes, and what a restore hands each window.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Window browse persistence")
@MainActor
struct WindowBrowsePersistenceTests {
    private func tab(_ title: String) -> QueryTab {
        QueryTab(id: UUID(), title: title, query: "SELECT 1", tabType: .table)
    }

    private func result(from state: TabDiskState) -> RestoreResult {
        RestoreResult(
            tabs: [],
            selectedTabId: nil,
            source: .disk,
            lastActiveDatabase: state.lastActiveDatabase,
            lastActiveSchema: state.lastActiveSchema,
            browseStateByWindowGroup: RestoreResult.browseStates(from: state)
        )
    }

    // MARK: - Per-group restore

    @Test("Two window groups saved on different databases each restore onto their own")
    func groupsRestoreOntoTheirOwnContainer() {
        let state = TabDiskState(
            tabs: [],
            selectedTabId: nil,
            lastActiveDatabase: "shop",
            lastActiveSchema: "public",
            windowBrowseStates: [
                PersistedWindowBrowse(windowGroupIndex: 0, database: "shop", schema: "public"),
                PersistedWindowBrowse(windowGroupIndex: 1, database: "analytics", schema: "reporting")
            ]
        )

        let restored = result(from: state)

        #expect(restored.browseState(forWindowGroupIndex: 0).database == "shop")
        #expect(restored.browseState(forWindowGroupIndex: 0).schema == "public")
        #expect(restored.browseState(forWindowGroupIndex: 1).database == "analytics")
        #expect(restored.browseState(forWindowGroupIndex: 1).schema == "reporting")
    }

    /// The whole point of the field: the group that was written last must not decide where the other
    /// windows land.
    @Test("A group's container is not overwritten by a later group's")
    func laterGroupDoesNotWinOverEarlier() {
        let state = TabDiskState(
            tabs: [],
            selectedTabId: nil,
            lastActiveDatabase: "analytics",
            lastActiveSchema: nil,
            windowBrowseStates: [
                PersistedWindowBrowse(windowGroupIndex: 0, database: "shop", schema: nil),
                PersistedWindowBrowse(windowGroupIndex: 1, database: "analytics", schema: nil)
            ]
        )

        #expect(result(from: state).browseState(forWindowGroupIndex: 0).database == "shop")
    }

    @Test("A group with nothing saved for it falls back to the single connection container")
    func unknownGroupFallsBackToLegacyValue() {
        let state = TabDiskState(
            tabs: [],
            selectedTabId: nil,
            lastActiveDatabase: "shop",
            lastActiveSchema: "public",
            windowBrowseStates: [
                PersistedWindowBrowse(windowGroupIndex: 0, database: "analytics", schema: "reporting")
            ]
        )

        let restored = result(from: state)

        #expect(restored.browseState(forWindowGroupIndex: 3).database == "shop")
        #expect(restored.browseState(forWindowGroupIndex: 3).schema == "public")
    }

    // MARK: - Legacy state

    /// State written by a build that kept one container per connection carries no per-group list at
    /// all. Every group has to fall back to that single value, which is exactly what those builds
    /// did, so upgrading changes nothing for a user rather than dropping them on the default.
    @Test("State written without per-window containers restores the single value to every group")
    func legacyStateAppliesToEveryGroup() throws {
        let json = """
        {"tabs":[],"selectedTabId":null,"lastActiveDatabase":"shop","lastActiveSchema":"public"}
        """
        let state = try JSONDecoder().decode(TabDiskState.self, from: Data(json.utf8))

        #expect(state.windowBrowseStates == nil)

        let restored = result(from: state)
        for groupIndex in 0..<3 {
            #expect(restored.browseState(forWindowGroupIndex: groupIndex).database == "shop")
            #expect(restored.browseState(forWindowGroupIndex: groupIndex).schema == "public")
        }
    }

    @Test("State with neither per-window nor legacy containers restores an unset cursor")
    func stateWithoutAnyContainerRestoresUnset() throws {
        let json = """
        {"tabs":[],"selectedTabId":null}
        """
        let state = try JSONDecoder().decode(TabDiskState.self, from: Data(json.utf8))

        #expect(result(from: state).browseState(forWindowGroupIndex: 0).isUnset)
    }

    // MARK: - Round-trip

    @Test("A window group's container round-trips through encode and decode")
    func browseStatesRoundTrip() throws {
        let state = TabDiskState(
            tabs: [],
            selectedTabId: nil,
            lastActiveDatabase: "shop",
            lastActiveSchema: nil,
            windowBrowseStates: [
                PersistedWindowBrowse(windowGroupIndex: 0, database: "shop", schema: nil),
                PersistedWindowBrowse(windowGroupIndex: 2, database: "analytics", schema: "reporting")
            ]
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(TabDiskState.self, from: data)

        #expect(decoded.windowBrowseStates == state.windowBrowseStates)
        #expect(decoded.lastActiveDatabase == "shop")
    }

    // MARK: - Save side

    @Test("A save writes one container per window group, and restore hands each group its own")
    func saveThenRestoreKeepsGroupsApart() async throws {
        let coordinator = TabPersistenceCoordinator(connectionId: UUID())
        let first = tab("Shop")
        let second = tab("Analytics")

        coordinator.saveNowSync(
            windowedTabs: [(tab: first, windowGroupIndex: 0), (tab: second, windowGroupIndex: 1)],
            selectedTabId: first.id,
            browseStates: [
                0: WindowBrowseState.seeded(database: "shop", schema: "public"),
                1: WindowBrowseState.seeded(database: "analytics", schema: nil)
            ]
        )

        let restored = await coordinator.restoreFromDisk()
        defer { coordinator.clearForUserClosedAllTabs() }

        #expect(restored.browseState(forWindowGroupIndex: 0).database == "shop")
        #expect(restored.browseState(forWindowGroupIndex: 0).schema == "public")
        #expect(restored.browseState(forWindowGroupIndex: 1).database == "analytics")
        #expect(restored.browseState(forWindowGroupIndex: 1).schema == nil)
    }

    /// Teardown order is not the save path's to control: on quit and on disconnect a window can be
    /// gone before the aggregated save runs, and a group whose cursor went missing would come back on
    /// the connection default instead of where the user left it.
    @Test("A group keeps its container when its window is already gone at save time")
    func lastKnownContainerSurvivesATornDownWindow() async throws {
        let coordinator = TabPersistenceCoordinator(connectionId: UUID())
        let first = tab("Shop")
        let second = tab("Analytics")
        let windowed = [(tab: first, windowGroupIndex: 0), (tab: second, windowGroupIndex: 1)]

        coordinator.saveNowSync(
            windowedTabs: windowed,
            selectedTabId: first.id,
            browseStates: [
                0: WindowBrowseState.seeded(database: "shop", schema: nil),
                1: WindowBrowseState.seeded(database: "analytics", schema: nil)
            ]
        )
        coordinator.saveNowSync(
            windowedTabs: windowed,
            selectedTabId: first.id,
            browseStates: [0: WindowBrowseState.seeded(database: "shop", schema: nil)]
        )

        let restored = await coordinator.restoreFromDisk()
        defer { coordinator.clearForUserClosedAllTabs() }

        #expect(restored.browseState(forWindowGroupIndex: 1).database == "analytics")
    }

    @Test("A cursor that names no container is never written")
    func unsetCursorIsNotPersisted() async throws {
        let coordinator = TabPersistenceCoordinator(connectionId: UUID())
        let only = tab("Draft")

        coordinator.saveNowSync(
            windowedTabs: [(tab: only, windowGroupIndex: 0)],
            selectedTabId: only.id,
            browseStates: [0: WindowBrowseState()]
        )

        let restored = await coordinator.restoreFromDisk()
        defer { coordinator.clearForUserClosedAllTabs() }

        #expect(restored.browseStateByWindowGroup.isEmpty)
        #expect(restored.browseState(forWindowGroupIndex: 0).isUnset)
    }
}
