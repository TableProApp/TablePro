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

    @Test("Empty search with the All scope shows only recents")
    func emptySearchShowsOnlyRecents() {
        let suite = makeDefaults()
        let connectionId = UUID()
        let items = sampleItems()
        let vm = makeViewModel(items: items, connectionId: connectionId, defaults: suite)
        #expect(vm.groups.isEmpty)

        vm.recordSelection(items[0])
        let vm2 = QuickSwitcherViewModel(connectionId: connectionId, services: .live, defaults: suite)
        vm2.allItems = items
        #expect(vm2.groups.count == 1)
        #expect(vm2.groups.first?.header == String(localized: "Recent"))
    }

    @Test("A browse scope lists every kind it covers")
    func browseScopeListsKinds() {
        let vm = makeViewModel(items: sampleItems())
        vm.scope = .tables
        let kinds = vm.groups.compactMap { $0.header }
        #expect(kinds.contains(String(localized: "Tables")))
        #expect(kinds.contains(String(localized: "Views")))
        #expect(!kinds.contains(String(localized: "Databases")))
    }

    @Test("Filtered search returns one headerless group of best matches")
    func filteredGroupHasNoHeader() async throws {
        let vm = makeViewModel(items: sampleItems())
        vm.searchText = "users"
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(vm.groups.count == 1)
        #expect(vm.groups.first?.header == nil)
        #expect(vm.flatItems.allSatisfy { $0.name.localizedCaseInsensitiveContains("u") })
    }

    @Test("Browse scope caps at maxResults")
    func filterCaps() {
        var items: [QuickSwitcherItem] = []
        for index in 0..<300 {
            items.append(QuickSwitcherItem(id: "t\(index)", name: "table_\(index)", kind: .table, subtitle: ""))
        }
        let vm = makeViewModel(items: items)
        vm.scope = .tables
        #expect(vm.flatItems.count == 200)
    }

    @Test("moveSelection by 1 advances to next item")
    func moveDownAdvances() {
        let vm = makeViewModel(items: sampleItems())
        vm.scope = .tables
        let first = vm.flatItems.first?.id
        #expect(vm.selectedItemId == first)
        vm.moveSelection(by: 1)
        #expect(vm.selectedItemId == vm.flatItems[1].id)
    }

    @Test("moveSelection clamps at the bounds")
    func moveSelectionClamps() {
        let vm = makeViewModel(items: sampleItems())
        vm.scope = .tables
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
        vm.scope = .tables
        let target = vm.flatItems[2]
        vm.selectedItemId = target.id
        #expect(vm.selectedItem()?.id == target.id)
    }

    @Test("selectedItem is nil when no selection")
    func selectedItemNilWhenNone() {
        let vm = makeViewModel(items: sampleItems())
        vm.scope = .tables
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

    @Test("Recent group caps at 10 entries, newest first")
    func recentGroupCapsAtLimit() {
        let suite = makeDefaults()
        let connectionId = UUID()
        var items: [QuickSwitcherItem] = []
        for index in 0..<15 {
            items.append(QuickSwitcherItem(id: "t\(index)", name: "table_\(index)", kind: .table, subtitle: ""))
        }
        let vm = makeViewModel(items: items, connectionId: connectionId, defaults: suite)
        for (index, item) in items.enumerated() {
            vm.recordSelection(item, at: Date(timeIntervalSinceNow: TimeInterval(index)))
        }

        let vm2 = QuickSwitcherViewModel(connectionId: connectionId, services: .live, defaults: suite)
        vm2.allItems = items
        let recentGroup = vm2.groups.first { $0.header == String(localized: "Recent") }
        #expect(recentGroup?.items.count == 10)
        #expect(recentGroup?.items.first?.id == items.last?.id)
    }

    @Test("Filtered results carry matched character indices")
    func filteredResultsCarryMatchedIndices() async throws {
        let vm = makeViewModel(items: sampleItems())
        vm.searchText = "usr"
        try await Task.sleep(nanoseconds: 200_000_000)
        let users = vm.flatItems.first { $0.id == "t1" }
        #expect(users?.matchedIndices == [0, 1, 3])
    }

    @Test("Frecency boosts a previously opened item over an equal match")
    func frecencyBoostsPreviouslyOpenedItem() async throws {
        let suite = makeDefaults()
        let connectionId = UUID()
        let items = [
            QuickSwitcherItem(id: "ta", name: "users_a", kind: .table, subtitle: ""),
            QuickSwitcherItem(id: "tb", name: "users_b", kind: .table, subtitle: "")
        ]
        let vm = makeViewModel(items: items, connectionId: connectionId, defaults: suite)
        vm.searchText = "users"
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(vm.flatItems.first?.id == "ta")

        vm.recordSelection(items[1])
        let vm2 = QuickSwitcherViewModel(connectionId: connectionId, services: .live, defaults: suite)
        vm2.allItems = items
        vm2.searchText = "users"
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(vm2.flatItems.first?.id == "tb")
    }

    @Test("Saved queries get their own section in the queries browse scope")
    func savedQueriesGetOwnSection() {
        var items = sampleItems()
        items.append(QuickSwitcherItem(
            id: "f1",
            name: "Monthly revenue",
            kind: .savedQuery,
            subtitle: "rev",
            payload: "SELECT SUM(total) FROM orders GROUP BY month;"
        ))
        let vm = makeViewModel(items: items)
        vm.scope = .queries
        let headers = vm.groups.compactMap(\.header)
        #expect(headers.contains(String(localized: "Saved Queries")))
    }

    @Test("Payload survives filtering")
    func payloadSurvivesFiltering() async throws {
        let items = [QuickSwitcherItem(
            id: "f1",
            name: "Monthly revenue",
            kind: .savedQuery,
            subtitle: "",
            payload: "SELECT SUM(total) FROM orders GROUP BY month;"
        )]
        let vm = makeViewModel(items: items)
        vm.searchText = "revenue"
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(vm.flatItems.first?.payload == "SELECT SUM(total) FROM orders GROUP BY month;")
    }

    @Test("Scope limits the empty-query view to its kinds")
    func scopeLimitsEmptyQueryView() {
        let vm = makeViewModel(items: sampleItems())
        vm.scope = .tables
        #expect(vm.flatItems.allSatisfy { [.table, .view, .systemTable].contains($0.kind) })
        vm.scope = .queries
        #expect(vm.flatItems.allSatisfy { [.savedQuery, .queryHistory].contains($0.kind) })
    }

    @Test("Scope limits filtered results to its kinds")
    func scopeLimitsFilteredResults() async throws {
        let vm = makeViewModel(items: sampleItems())
        vm.scope = .containers
        vm.searchText = "r"
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(vm.flatItems.allSatisfy { [.database, .schema].contains($0.kind) })
        #expect(vm.flatItems.contains { $0.id == "d1" })
    }

    @Test("A table already open in a tab outranks an equal match")
    func openTabOutranksEqualMatch() async throws {
        let items = [
            QuickSwitcherItem(id: "ta", name: "users_a", kind: .table, subtitle: ""),
            QuickSwitcherItem(id: "tb", name: "users_b", kind: .table, subtitle: "", isOpenInTab: true)
        ]
        let vm = makeViewModel(items: items)
        vm.searchText = "users"
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(vm.flatItems.first?.id == "tb")
    }

    @Test("Query matching only the subtitle still surfaces the item")
    func subtitleMatchSurfacesItem() async throws {
        let vm = makeViewModel(items: sampleItems())
        vm.searchText = "mydb"
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(vm.flatItems.contains { $0.id == "h1" })
        #expect(vm.flatItems.first { $0.id == "h1" }?.matchedIndices.isEmpty == true)
    }

    @Test("Search keeps selection if still in results")
    func searchKeepsSelectionWhenPresent() async throws {
        let vm = makeViewModel(items: sampleItems())
        vm.selectedItemId = "t1"
        vm.searchText = "users"
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(vm.flatItems.contains(where: { $0.id == "t1" }))
        #expect(vm.selectedItemId == "t1")
    }

    @Test("Search resets selection when previous selection is filtered out")
    func searchResetsSelectionWhenAbsent() async throws {
        let vm = makeViewModel(items: sampleItems())
        vm.selectedItemId = "d1"
        vm.searchText = "users"
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(vm.flatItems.contains(where: { $0.id == "d1" }) == false)
        #expect(vm.selectedItemId == vm.flatItems.first?.id)
    }

    @Test("listHeight is zero when there are no items")
    func listHeightZeroWhenEmpty() {
        let vm = makeViewModel(items: [])
        #expect(vm.listHeight(rowHeight: 30, headerHeight: 28, maxVisibleRows: 9) == 0)
    }

    @Test("listHeight for a single filtered result is one row")
    func listHeightSingleFilteredRow() async throws {
        let vm = makeViewModel(items: [QuickSwitcherItem(id: "t1", name: "users", kind: .table, subtitle: "")])
        vm.searchText = "users"
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(vm.groups.first?.header == nil)
        #expect(vm.listHeight(rowHeight: 30, headerHeight: 28, maxVisibleRows: 9) == 30)
    }

    @Test("listHeight at the row cap shows every row")
    func listHeightAtCap() async throws {
        var items: [QuickSwitcherItem] = []
        for index in 0..<9 {
            items.append(QuickSwitcherItem(id: "t\(index)", name: "tbl_\(index)", kind: .table, subtitle: ""))
        }
        let vm = makeViewModel(items: items)
        vm.searchText = "tbl"
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(vm.flatItems.count == 9)
        #expect(vm.listHeight(rowHeight: 30, headerHeight: 28, maxVisibleRows: 9) == 270)
    }

    @Test("listHeight caps at maxVisibleRows when results overflow")
    func listHeightCapsWhenOverflowing() async throws {
        var items: [QuickSwitcherItem] = []
        for index in 0..<20 {
            items.append(QuickSwitcherItem(id: "t\(index)", name: "tbl_\(index)", kind: .table, subtitle: ""))
        }
        let vm = makeViewModel(items: items)
        vm.searchText = "tbl"
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(vm.flatItems.count == 20)
        #expect(vm.listHeight(rowHeight: 30, headerHeight: 28, maxVisibleRows: 9) == 270)
    }

    @Test("listHeight for a browse scope counts section headers")
    func listHeightCountsSectionHeaders() {
        let vm = makeViewModel(items: sampleItems())
        vm.scope = .tables
        #expect(vm.groups.filter { $0.header != nil }.count == 2)
        #expect(vm.flatItems.count == 3)
        #expect(vm.listHeight(rowHeight: 30, headerHeight: 28, maxVisibleRows: 9) == 146)
    }

    @Test("A recorded selection adds a Recent header and row to the empty-query view")
    func listHeightIncludesRecentHeader() {
        let suite = makeDefaults()
        let connectionId = UUID()
        let items = sampleItems()
        let vm = makeViewModel(items: items, connectionId: connectionId, defaults: suite)
        #expect(vm.listHeight(rowHeight: 30, headerHeight: 28, maxVisibleRows: 100) == 0)
        vm.recordSelection(items[0])

        let vm2 = QuickSwitcherViewModel(connectionId: connectionId, services: .live, defaults: suite)
        vm2.allItems = items
        #expect(vm2.listHeight(rowHeight: 30, headerHeight: 28, maxVisibleRows: 100) == 58)
    }

    @Test("listHeight clamps to the cap when sections and rows overflow")
    func listHeightClampsWithHeaders() {
        var items: [QuickSwitcherItem] = []
        for index in 0..<30 {
            items.append(QuickSwitcherItem(id: "t\(index)", name: "table_\(index)", kind: .table, subtitle: ""))
            items.append(QuickSwitcherItem(id: "v\(index)", name: "view_\(index)", kind: .view, subtitle: "View"))
        }
        let vm = makeViewModel(items: items)
        vm.scope = .tables
        #expect(vm.groups.filter { $0.header != nil }.count >= 2)
        #expect(vm.listHeight(rowHeight: 30, headerHeight: 28, maxVisibleRows: 9) == 270)
    }

    @Test("isLoading is true until the first load finishes")
    func isLoadingStartsTrue() {
        let vm = QuickSwitcherViewModel(connectionId: UUID(), services: .live, defaults: makeDefaults())
        #expect(vm.isLoading)
    }
}
