import Foundation
@testable import TablePro
import Testing

@Suite("Tab persistence write gate")
@MainActor
struct TabPersistenceWriteGateTests {
    private func makeTab(_ title: String) -> QueryTab {
        var tab = QueryTab()
        tab.title = title
        return tab
    }

    /// The regression this guards: a save carrying a partial list used to replace the full saved
    /// set, so tabs that had not been restored yet were erased from disk.
    @Test("A save before any restore is refused")
    func saveIsRefusedBeforeRestoreCompletes() async {
        let connectionId = UUID()
        let coordinator = TabPersistenceCoordinator(connectionId: connectionId)
        defer { TabDiskActor.clearSync(connectionId: connectionId) }

        coordinator.saveNowSync(tabs: [makeTab("Query 1")], selectedTabId: nil)

        let loaded = await TabDiskActor.shared.load(connectionId: connectionId)
        #expect(loaded == nil || loaded?.tabs.isEmpty == true)
    }

    /// A connection with nothing on disk has still consulted it, so it must be able to save.
    @Test("A restore that finds nothing still opens the gate")
    func emptyRestoreOpensTheGate() async {
        let connectionId = UUID()
        let coordinator = TabPersistenceCoordinator(connectionId: connectionId)
        defer { TabDiskActor.clearSync(connectionId: connectionId) }

        let restored = await coordinator.restoreFromDisk()
        #expect(restored.tabs.isEmpty)

        coordinator.saveNowSync(tabs: [makeTab("Query 1")], selectedTabId: nil)

        let loaded = await TabDiskActor.shared.load(connectionId: connectionId)
        #expect(loaded?.tabs.count == 1)
    }

    @Test("An empty tab list is never written over saved state")
    func emptyListNeverClears() async {
        let connectionId = UUID()
        let coordinator = TabPersistenceCoordinator(connectionId: connectionId)
        defer { TabDiskActor.clearSync(connectionId: connectionId) }

        _ = await coordinator.restoreFromDisk()
        coordinator.saveNowSync(tabs: [makeTab("Keep me")], selectedTabId: nil)

        coordinator.saveNowSync(tabs: [], selectedTabId: nil)

        let loaded = await TabDiskActor.shared.load(connectionId: connectionId)
        #expect(loaded?.tabs.count == 1)
    }

    /// Only the user closing every tab discards saved state.
    @Test("The explicit clear removes saved state")
    func explicitClearRemovesState() async {
        let connectionId = UUID()
        let coordinator = TabPersistenceCoordinator(connectionId: connectionId)
        defer { TabDiskActor.clearSync(connectionId: connectionId) }

        _ = await coordinator.restoreFromDisk()
        coordinator.saveNowSync(tabs: [makeTab("Query 1")], selectedTabId: nil)

        coordinator.clearForUserClosedAllTabs()

        let loaded = await TabDiskActor.shared.load(connectionId: connectionId)
        #expect(loaded == nil || loaded?.tabs.isEmpty == true)
    }
}
