import Foundation
@testable import TablePro
import Testing

@Suite("QueryTabManager.adoptTab")
@MainActor
struct QueryTabManagerAdoptTabTests {
    @Test("An adopted tab keeps its identity and content instead of being rebuilt")
    func adoptedTabKeepsItsIdentity() {
        let manager = QueryTabManager()
        let restored = QueryTab(title: "Restored", query: "SELECT 1")

        manager.adoptTab(restored)

        #expect(manager.tabs.count == 1)
        #expect(manager.tabs.first?.id == restored.id)
        #expect(manager.tabs.first?.content.query == "SELECT 1")
        #expect(manager.tabs.first?.title == "Restored")
    }

    @Test("An adopted tab becomes the selected tab")
    func adoptedTabIsSelected() {
        let manager = QueryTabManager()
        let restored = QueryTab(query: "SELECT 1")

        manager.adoptTab(restored)

        #expect(manager.selectedTabId == restored.id)
    }

    /// Reopening into the empty window left behind by closing the last tab must not strand a blank
    /// tab beside the restored one.
    @Test("Adopting into an empty manager leaves exactly one tab")
    func adoptingIntoEmptyManagerLeavesOneTab() {
        let manager = QueryTabManager()
        #expect(manager.tabs.isEmpty)

        manager.adoptTab(QueryTab(query: "SELECT restored"))

        #expect(manager.tabs.count == 1)
        #expect(manager.tabs.first?.content.query == "SELECT restored")
    }

    @Test("Claiming focus marks the adopted tab as the one to focus")
    func claimingFocusTargetsTheAdoptedTab() {
        let manager = QueryTabManager()
        let restored = QueryTab(query: "SELECT 1")

        manager.adoptTab(restored, claimFocus: true)

        #expect(manager.pendingFocusTabId == restored.id)
    }
}
