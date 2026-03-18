//
//  QuickSwitcherViewModelTests.swift
//  TableProTests
//
//  Tests for QuickSwitcherViewModel filtering and navigation
//

@testable import TablePro
import Testing

@MainActor
struct QuickSwitcherViewModelTests {
    // MARK: - Helpers

    private func makeViewModel(items: [QuickSwitcherItem]) -> QuickSwitcherViewModel {
        let vm = QuickSwitcherViewModel()
        vm.allItems = items
        return vm
    }

    private func sampleItems() -> [QuickSwitcherItem] {
        [
            QuickSwitcherItem(id: "t1", name: "users", kind: .table, subtitle: ""),
            QuickSwitcherItem(id: "t2", name: "orders", kind: .table, subtitle: ""),
            QuickSwitcherItem(id: "v1", name: "active_users", kind: .view, subtitle: ""),
            QuickSwitcherItem(id: "d1", name: "production", kind: .database, subtitle: "Database"),
            QuickSwitcherItem(id: "h1", name: "SELECT * FROM users;", kind: .queryHistory, subtitle: "mydb"),
        ]
    }

    // MARK: - Filtering

    @Test("Empty search shows all items")
    func emptySearchShowsAll() {
        let vm = makeViewModel(items: sampleItems())
        vm.searchText = ""
        // Trigger immediate filter (bypass debounce)
        #expect(vm.filteredItems.count == 5)
    }

    @Test("Search filters by name")
    func searchFiltersByName() async throws {
        let vm = makeViewModel(items: sampleItems())
        vm.searchText = "users"
        // Wait for debounce
        try await Task.sleep(for: .milliseconds(100))
        // "users" and "active_users" should match, plus the history item containing "users"
        #expect(vm.filteredItems.count >= 2)
        #expect(vm.filteredItems.allSatisfy { $0.score > 0 })
    }

    @Test("Non-matching search returns empty")
    func nonMatchingSearchReturnsEmpty() async throws {
        let vm = makeViewModel(items: sampleItems())
        vm.searchText = "zzz"
        try await Task.sleep(for: .milliseconds(100))
        #expect(vm.filteredItems.isEmpty)
    }

    @Test("Filter caps at 100 results")
    func filterCapsAtMaxResults() {
        var items: [QuickSwitcherItem] = []
        for i in 0..<200 {
            items.append(QuickSwitcherItem(id: "t\(i)", name: "table_\(i)", kind: .table, subtitle: ""))
        }
        let vm = makeViewModel(items: items)
        vm.searchText = ""
        #expect(vm.filteredItems.count == 100)
    }

    // MARK: - Navigation

    @Test("moveDown selects next item")
    func moveDownSelectsNext() {
        let vm = makeViewModel(items: sampleItems())
        vm.searchText = ""
        // After setting items, first item is auto-selected
        #expect(vm.selectedItemId == vm.filteredItems.first?.id)
        vm.moveDown()
        #expect(vm.selectedItemId == vm.filteredItems[1].id)
    }

    @Test("moveUp selects previous item")
    func moveUpSelectsPrevious() {
        let vm = makeViewModel(items: sampleItems())
        vm.searchText = ""
        vm.selectedItemId = vm.filteredItems[2].id
        vm.moveUp()
        #expect(vm.selectedItemId == vm.filteredItems[1].id)
    }

    @Test("moveUp clamps to first item")
    func moveUpClampsToFirst() {
        let vm = makeViewModel(items: sampleItems())
        vm.searchText = ""
        vm.selectedItemId = vm.filteredItems.first?.id
        vm.moveUp()
        #expect(vm.selectedItemId == vm.filteredItems.first?.id)
    }

    @Test("moveDown clamps to last item")
    func moveDownClampsToEnd() {
        let vm = makeViewModel(items: sampleItems())
        vm.searchText = ""
        vm.selectedItemId = vm.filteredItems.last?.id
        vm.moveDown()
        #expect(vm.selectedItemId == vm.filteredItems.last?.id)
    }

    @Test("selectedItem returns correct item")
    func selectedItemReturnsCorrectItem() {
        let vm = makeViewModel(items: sampleItems())
        vm.searchText = ""
        let secondItem = vm.filteredItems[1]
        vm.selectedItemId = secondItem.id
        #expect(vm.selectedItem?.id == secondItem.id)
        #expect(vm.selectedItem?.name == secondItem.name)
    }

    @Test("selectedItem returns nil for empty list")
    func selectedItemReturnsNilForEmpty() {
        let vm = makeViewModel(items: [])
        #expect(vm.selectedItem == nil)
    }

    @Test("Search resets selection to first item")
    func searchResetsSelection() async throws {
        let vm = makeViewModel(items: sampleItems())
        vm.searchText = ""
        vm.selectedItemId = vm.filteredItems[3].id
        vm.searchText = "users"
        try await Task.sleep(for: .milliseconds(100))
        #expect(vm.selectedItemId == vm.filteredItems.first?.id)
    }

    // MARK: - Grouped Items

    @Test("groupedItems returns correct section kinds when not searching")
    func groupedItemsReturnsSections() {
        let vm = makeViewModel(items: sampleItems())
        vm.searchText = ""
        let groups = vm.groupedItems
        let kinds = groups.map(\.kind)
        #expect(kinds.contains(.table))
        #expect(kinds.contains(.view))
        #expect(kinds.contains(.database))
        #expect(kinds.contains(.queryHistory))
    }

    @Test("groupedItems is empty when no items")
    func groupedItemsEmptyWhenNoItems() {
        let vm = makeViewModel(items: [])
        #expect(vm.groupedItems.isEmpty)
    }

    @Test("selectedItem returns nil when selectedItemId does not match any item")
    func selectedItemNilForBogusId() {
        let vm = makeViewModel(items: sampleItems())
        vm.selectedItemId = "nonexistent_id"
        #expect(vm.selectedItem == nil)
    }

    @Test("moveUp does nothing when selectedItemId is nil")
    func moveUpDoesNothingWhenNil() {
        let vm = makeViewModel(items: sampleItems())
        vm.selectedItemId = nil
        vm.moveUp()
        #expect(vm.selectedItemId == nil)
    }

    @Test("moveDown does nothing when selectedItemId is nil")
    func moveDownDoesNothingWhenNil() {
        let vm = makeViewModel(items: sampleItems())
        vm.selectedItemId = nil
        vm.moveDown()
        #expect(vm.selectedItemId == nil)
    }
}
