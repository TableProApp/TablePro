//
//  QuickSwitcherViewModelTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct QuickSwitcherViewModelTests {
    private func makeDefaults() -> UserDefaults {
        guard let suite = UserDefaults(suiteName: "QuickSwitcherTests.\(UUID().uuidString)") else {
            return .standard
        }
        return suite
    }

    private func makeViewModel(
        items: [QuickSwitcherItem],
        connectionId: UUID = UUID(),
        defaults: UserDefaults? = nil
    ) -> QuickSwitcherViewModel {
        let suite = defaults ?? makeDefaults()
        let vm = QuickSwitcherViewModel(connectionId: connectionId, services: .live, defaults: suite)
        vm.allItems = items
        return vm
    }

    private func sampleItems() -> [QuickSwitcherItem] {
        [
            QuickSwitcherItem(id: "t1", name: "users", kind: .table, subtitle: ""),
            QuickSwitcherItem(id: "t2", name: "orders", kind: .table, subtitle: ""),
            QuickSwitcherItem(id: "v1", name: "active_users", kind: .view, subtitle: "View"),
            QuickSwitcherItem(id: "d1", name: "production", kind: .database, subtitle: "Database"),
            QuickSwitcherItem(id: "h1", name: "SELECT * FROM users;", kind: .queryHistory, subtitle: "mydb")
        ]
    }

    @Test("Empty search builds one group per kind")
    func emptySearchGroupsByKind() {
        let vm = makeViewModel(items: sampleItems())
        let kinds = vm.groups.compactMap { $0.header }
        #expect(kinds.contains(String(localized: "Tables")))
        #expect(kinds.contains(String(localized: "Views")))
        #expect(kinds.contains(String(localized: "Databases")))
        #expect(kinds.contains(String(localized: "Recent Queries")))
    }

    @Test("Filtered search returns one headerless group of best matches")
    func filteredGroupHasNoHeader() async throws {
        let vm = makeViewModel(items: sampleItems())
        vm.searchText = "users"
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(vm.groups.count == 1)
        #expect(vm.groups.first?.header == nil)
        #expect(vm.flatItems.allSatisfy { $0.name.localizedCaseInsensitiveContains("u") })
    }

    @Test("Filter caps at maxResults")
    func filterCaps() {
        var items: [QuickSwitcherItem] = []
        for index in 0..<300 {
            items.append(QuickSwitcherItem(id: "t\(index)", name: "table_\(index)", kind: .table, subtitle: ""))
        }
        let vm = makeViewModel(items: items)
        #expect(vm.flatItems.count == 200)
    }

    @Test("moveSelection by 1 advances to next item")
    func moveDownAdvances() {
        let vm = makeViewModel(items: sampleItems())
        let first = vm.flatItems.first?.id
        #expect(vm.selectedItemId == first)
        vm.moveSelection(by: 1)
        #expect(vm.selectedItemId == vm.flatItems[1].id)
    }

    @Test("moveSelection clamps at the bounds")
    func moveSelectionClamps() {
        let vm = makeViewModel(items: sampleItems())
        vm.selectedItemId = vm.flatItems.first?.id
        vm.moveSelection(by: -1)
        #expect(vm.selectedItemId == vm.flatItems.first?.id)
        vm.selectedItemId = vm.flatItems.last?.id
        vm.moveSelection(by: 1)
        #expect(vm.selectedItemId == vm.flatItems.last?.id)
    }

    @Test("moveSelection on empty list yields nil")
    func moveSelectionOnEmpty() {
        let vm = makeViewModel(items: [])
        vm.moveSelection(by: 1)
        #expect(vm.selectedItemId == nil)
    }

    @Test("selectedItem returns the current selection")
    func selectedItemReturnsCurrent() {
        let vm = makeViewModel(items: sampleItems())
        let target = vm.flatItems[2]
        vm.selectedItemId = target.id
        #expect(vm.selectedItem()?.id == target.id)
    }

    @Test("selectedItem is nil when no selection")
    func selectedItemNilWhenNone() {
        let vm = makeViewModel(items: sampleItems())
        vm.selectedItemId = nil
        #expect(vm.selectedItem() == nil)
    }

    @Test("recordSelection inserts MRU and Recent group appears next time")
    func recordSelectionAddsRecent() {
        let suite = makeDefaults()
        let connectionId = UUID()
        let items = sampleItems()
        let vm = makeViewModel(items: items, connectionId: connectionId, defaults: suite)
        let chosen = items[1]
        vm.recordSelection(chosen)

        let vm2 = QuickSwitcherViewModel(connectionId: connectionId, services: .live, defaults: suite)
        vm2.allItems = items
        let recentGroup = vm2.groups.first { $0.header == String(localized: "Recent") }
        #expect(recentGroup?.items.first?.id == chosen.id)
    }

    @Test("recordSelection trims MRU to 10 entries")
    func mruTrimsToLimit() {
        let suite = makeDefaults()
        let connectionId = UUID()
        var items: [QuickSwitcherItem] = []
        for index in 0..<15 {
            items.append(QuickSwitcherItem(id: "t\(index)", name: "table_\(index)", kind: .table, subtitle: ""))
        }
        let vm = makeViewModel(items: items, connectionId: connectionId, defaults: suite)
        for item in items {
            vm.recordSelection(item)
        }
        let stored = suite.stringArray(forKey: "QuickSwitcher.mru.\(connectionId.uuidString)") ?? []
        #expect(stored.count == 10)
        #expect(stored.first == items.last?.id)
    }

    @Test("Search keeps selection if still in results")
    func searchKeepsSelectionWhenPresent() async throws {
        let vm = makeViewModel(items: sampleItems())
        guard let usersItem = vm.flatItems.first(where: { $0.id == "t1" }) else {
            Issue.record("Expected t1 to be present")
            return
        }
        vm.selectedItemId = usersItem.id
        vm.searchText = "users"
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(vm.flatItems.contains(where: { $0.id == usersItem.id }))
        #expect(vm.selectedItemId == usersItem.id)
    }

    @Test("Search resets selection when previous selection is filtered out")
    func searchResetsSelectionWhenAbsent() async throws {
        let vm = makeViewModel(items: sampleItems())
        vm.selectedItemId = "d1"
        vm.searchText = "users"
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(vm.flatItems.contains(where: { $0.id == "d1" }) == false)
        #expect(vm.selectedItemId == vm.flatItems.first?.id)
    }
}
