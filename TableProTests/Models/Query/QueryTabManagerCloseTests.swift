import Foundation
@testable import TablePro
import Testing

@Suite("Query tab manager tab list operations")
@MainActor
struct QueryTabManagerCloseTests {
    private func makeManager(tabCount: Int) -> QueryTabManager {
        let manager = QueryTabManager()
        for index in 0..<tabCount {
            manager.addTab(title: "Tab \(index + 1)")
        }
        return manager
    }

    @Test("Adding tabs keeps them all, rather than replacing the one already open")
    func addAccumulates() {
        let manager = makeManager(tabCount: 3)

        #expect(manager.tabs.count == 3)
        #expect(manager.selectedTab?.title == "Tab 3")
    }

    @Test("Closing the selected tab selects the one that took its place")
    func closeSelectsSuccessor() throws {
        let manager = makeManager(tabCount: 3)
        let middle = try #require(manager.tabs.dropFirst().first)
        manager.selectedTabId = middle.id

        manager.closeTab(id: middle.id)

        #expect(manager.tabs.count == 2)
        #expect(manager.selectedTab?.title == "Tab 3")
    }

    @Test("Closing the last tab in the list falls back to the new last tab")
    func closeLastSelectsPrevious() throws {
        let manager = makeManager(tabCount: 3)
        let last = try #require(manager.tabs.last)
        manager.selectedTabId = last.id

        manager.closeTab(id: last.id)

        #expect(manager.tabs.count == 2)
        #expect(manager.selectedTab?.title == "Tab 2")
    }

    @Test("Closing an unselected tab leaves the selection alone")
    func closeOtherKeepsSelection() throws {
        let manager = makeManager(tabCount: 3)
        let first = try #require(manager.tabs.first)
        let last = try #require(manager.tabs.last)
        manager.selectedTabId = last.id

        manager.closeTab(id: first.id)

        #expect(manager.tabs.count == 2)
        #expect(manager.selectedTab?.id == last.id)
    }

    @Test("Closing every tab empties the list and clears the selection")
    func closingAllEmptiesList() {
        let manager = makeManager(tabCount: 2)

        for tab in manager.tabs {
            manager.closeTab(id: tab.id)
        }

        #expect(manager.tabs.isEmpty)
        #expect(manager.selectedTab == nil)
    }

    @Test("Closing a tab the manager does not hold changes nothing")
    func closeUnknownIsIgnored() {
        let manager = makeManager(tabCount: 2)

        manager.closeTab(id: UUID())

        #expect(manager.tabs.count == 2)
    }

    @Test("Selecting by position is one-based at the call site and clamped")
    func selectByIndex() {
        let manager = makeManager(tabCount: 3)

        manager.selectTab(at: 0)
        #expect(manager.selectedTab?.title == "Tab 1")

        manager.selectTab(at: 99)
        #expect(manager.selectedTab?.title == "Tab 1")
    }

    @Test("Cycling wraps in both directions")
    func cycleWraps() {
        let manager = makeManager(tabCount: 3)
        manager.selectTab(at: 2)

        manager.selectTab(offsetBy: 1)
        #expect(manager.selectedTab?.title == "Tab 1")

        manager.selectTab(offsetBy: -1)
        #expect(manager.selectedTab?.title == "Tab 3")
    }
}
