//
//  DatabaseSwitcherFilterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct DatabaseSwitcherFilterTests {
    private func makeViewModel(
        databaseNames: [String],
        filter: Set<String> = [],
        systemNames: [String] = []
    ) -> DatabaseSwitcherViewModel {
        let sidebarState = SharedSidebarState()
        sidebarState.databaseFilterSelected = filter
        let vm = DatabaseSwitcherViewModel(
            connectionId: UUID(),
            currentDatabase: nil,
            databaseType: .mysql,
            sidebarState: sidebarState
        )
        vm.databases = databaseNames.map { name in
            DatabaseMetadata.minimal(name: name, isSystem: systemNames.contains(name))
        }
        return vm
    }

    @Test("Empty search returns every database")
    func emptySearchReturnsAll() {
        let vm = makeViewModel(databaseNames: ["app", "analytics", "staging"])
        #expect(vm.filteredDatabases.count == 3)
    }

    @Test("Search matches subsequences, not just substrings")
    func searchMatchesSubsequence() {
        let vm = makeViewModel(databaseNames: ["analytics_prod", "staging"])
        vm.searchText = "anprd"
        #expect(vm.filteredDatabases.map(\.name) == ["analytics_prod"])
    }

    @Test("Better matches rank first")
    func betterMatchesRankFirst() {
        let vm = makeViewModel(databaseNames: ["my_app_db", "app"])
        vm.searchText = "app"
        #expect(vm.filteredDatabases.first?.name == "app")
    }

    @Test("Non-matching search returns nothing")
    func nonMatchingSearchReturnsNothing() {
        let vm = makeViewModel(databaseNames: ["app", "analytics"])
        vm.searchText = "zzz"
        #expect(vm.filteredDatabases.isEmpty)
    }

    @Test("Sidebar filter narrows the database list to the selected set")
    func sidebarFilterNarrowsList() {
        let vm = makeViewModel(
            databaseNames: ["app", "analytics", "staging", "logs"],
            filter: ["app", "staging"]
        )
        #expect(Set(vm.filteredDatabases.map(\.name)) == ["app", "staging"])
    }

    @Test("Empty sidebar filter still hides system databases")
    func emptySidebarFilterHidesSystemDatabases() {
        let vm = makeViewModel(
            databaseNames: ["app", "analytics", "staging"],
            systemNames: ["analytics"]
        )
        #expect(vm.filteredDatabases.map(\.name) == ["app", "staging"])
    }

    @Test("Sidebar filter keeps hiding system databases even when selected")
    func sidebarFilterHidesSystemDatabasesWhenSelected() {
        let vm = makeViewModel(
            databaseNames: ["app", "mysql", "sys"],
            filter: ["app", "mysql", "sys"],
            systemNames: ["mysql", "sys"]
        )
        #expect(vm.filteredDatabases.map(\.name) == ["app"])
    }
}
