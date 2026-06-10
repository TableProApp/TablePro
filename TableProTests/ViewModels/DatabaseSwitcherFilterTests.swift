//
//  DatabaseSwitcherFilterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct DatabaseSwitcherFilterTests {
    private func makeViewModel(databaseNames: [String]) -> DatabaseSwitcherViewModel {
        let vm = DatabaseSwitcherViewModel(
            connectionId: UUID(),
            currentDatabase: nil,
            databaseType: .mysql
        )
        vm.databases = databaseNames.map { DatabaseMetadata.minimal(name: $0) }
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
}
