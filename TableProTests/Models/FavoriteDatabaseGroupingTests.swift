//
//  FavoriteDatabaseGroupingTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("Favorite database grouping")
struct FavoriteDatabaseGroupingTests {
    private let connectionId = UUID()

    private func entry(_ database: String, _ environment: FavoriteDatabaseEnvironment) -> FavoriteDatabaseEntry {
        FavoriteDatabaseEntry(
            connectionId: connectionId,
            database: database,
            environment: environment
        )
    }

    @Test("Groups use environment order and database names sort naturally")
    func deterministicGrouping() {
        let groups = FavoriteDatabaseGrouping.groups(
            entries: [
                entry("prod", .production),
                entry("dev10", .development),
                entry("dev2", .development),
                entry("misc", .none),
                entry("test", .testing)
            ],
            searchText: "",
            filter: .all
        )

        #expect(groups.map(\.environment) == [.development, .testing, .production, .none])
        #expect(groups.first?.entries.map(\.database) == ["dev2", "dev10"])
    }

    @Test("Environment filter keeps only its group")
    func filtersByEnvironment() {
        let entries: Set<FavoriteDatabaseEntry> = [
            entry("dev", .development),
            entry("misc", .none),
            entry("prod", .production)
        ]
        let groups = FavoriteDatabaseGrouping.groups(
            entries: entries,
            searchText: "",
            filter: .production
        )
        let unassigned = FavoriteDatabaseGrouping.groups(
            entries: entries,
            searchText: "",
            filter: .unassigned
        )

        #expect(groups.count == 1)
        #expect(groups.first?.entries.map(\.database) == ["prod"])
        #expect(unassigned.count == 1)
        #expect(unassigned.first?.entries.map(\.database) == ["misc"])
    }

    @Test("Search matches a database or its environment title")
    func searchMatchesNamesAndEnvironment() {
        let entries: Set<FavoriteDatabaseEntry> = [
            entry("billing", .development),
            entry("warehouse", .production)
        ]

        let nameMatch = FavoriteDatabaseGrouping.groups(
            entries: entries,
            searchText: "bill",
            filter: .all
        )
        let environmentMatch = FavoriteDatabaseGrouping.groups(
            entries: entries,
            searchText: "Production",
            filter: .all
        )

        #expect(nameMatch.flatMap(\.entries).map(\.database) == ["billing"])
        #expect(environmentMatch.flatMap(\.entries).map(\.database) == ["warehouse"])
    }

    @Test("No matches produce no empty groups")
    func hidesEmptyGroups() {
        let groups = FavoriteDatabaseGrouping.groups(
            entries: [entry("app", .development)],
            searchText: "missing",
            filter: .all
        )

        #expect(groups.isEmpty)
    }
}
