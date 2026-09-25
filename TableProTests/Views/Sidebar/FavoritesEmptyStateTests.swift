//
//  FavoritesEmptyStateTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

struct FavoritesEmptyStateTests {
    private func input(
        isInitialLoadComplete: Bool = true,
        hasAnyFavorite: Bool = true,
        hasVisibleContent: Bool = false,
        searchText: String = "",
        isEnvironmentFiltered: Bool = false
    ) -> FavoritesEmptyState.Input {
        FavoritesEmptyState.Input(
            isInitialLoadComplete: isInitialLoadComplete,
            hasAnyFavorite: hasAnyFavorite,
            hasVisibleContent: hasVisibleContent,
            searchText: searchText,
            isEnvironmentFiltered: isEnvironmentFiltered
        )
    }

    @Test("Anything visible wins over every empty state")
    func contentWins() {
        #expect(
            FavoritesEmptyState.resolve(input(
                hasVisibleContent: true,
                searchText: "nothing matches this",
                isEnvironmentFiltered: true
            )) == .content
        )
    }

    @Test("Nothing loaded yet and nothing stored reads as loading")
    func loading() {
        #expect(
            FavoritesEmptyState.resolve(input(isInitialLoadComplete: false, hasAnyFavorite: false))
                == .loading
        )
    }

    @Test("A connection with no favorites at all gets the onboarding state")
    func noFavorites() {
        #expect(FavoritesEmptyState.resolve(input(hasAnyFavorite: false)) == .noFavorites)
    }

    @Test("A failed search reports the term the user typed")
    func searchMiss() {
        #expect(FavoritesEmptyState.resolve(input(searchText: "orders")) == .noSearchMatch("orders"))
    }

    /// The bug: an environment filter that matched nothing rendered `ContentUnavailableView.search`
    /// for a search the user never ran, so a persisted filter greeted them with "No Results" and an
    /// empty query on the next launch.
    @Test("A filter miss with no search term is a filter state, not a search state")
    func filterMissIsNotASearchMiss() {
        #expect(
            FavoritesEmptyState.resolve(input(searchText: "", isEnvironmentFiltered: true))
                == .noFilterMatch
        )
    }

    @Test("A search term wins over the filter when both are narrowing")
    func searchWinsOverFilter() {
        #expect(
            FavoritesEmptyState.resolve(input(searchText: "app", isEnvironmentFiltered: true))
                == .noSearchMatch("app")
        )
    }

    @Test("Favorites exist, nothing is narrowing, and nothing shows: still the onboarding state")
    func neitherNarrowing() {
        #expect(FavoritesEmptyState.resolve(input()) == .noFavorites)
    }

    // MARK: - hasAnyFavorite

    /// The question is whether the user owns a favorite at all. A list the filter field or the
    /// browsed database has already narrowed cannot answer it, and reading "nothing matched" as
    /// "you own nothing" put the onboarding view over a full Team Library.
    @Test("A Team Library query counts as owning a favorite")
    func teamLibraryQueriesCountAsFavorites() {
        #expect(FavoritesEmptyState.hasAnyFavorite(
            hasQueries: false,
            favoriteTableCount: 0,
            favoriteDatabaseCount: 0,
            teamLibraryQueryCount: 1
        ))
    }

    @Test("A favorite table counts even while another database is browsed")
    func favoriteTablesCountAcrossDatabases() {
        #expect(FavoritesEmptyState.hasAnyFavorite(
            hasQueries: false,
            favoriteTableCount: 3,
            favoriteDatabaseCount: 0,
            teamLibraryQueryCount: 0
        ))
    }

    @Test("A saved query counts on its own")
    func savedQueriesCount() {
        #expect(FavoritesEmptyState.hasAnyFavorite(
            hasQueries: true,
            favoriteTableCount: 0,
            favoriteDatabaseCount: 0,
            teamLibraryQueryCount: 0
        ))
    }

    @Test("A favorite database counts on its own")
    func favoriteDatabasesCount() {
        #expect(FavoritesEmptyState.hasAnyFavorite(
            hasQueries: false,
            favoriteTableCount: 0,
            favoriteDatabaseCount: 2,
            teamLibraryQueryCount: 0
        ))
    }

    @Test("Owning nothing at all is the only way to reach the onboarding state")
    func nothingOwnedIsFalse() {
        #expect(FavoritesEmptyState.hasAnyFavorite(
            hasQueries: false,
            favoriteTableCount: 0,
            favoriteDatabaseCount: 0,
            teamLibraryQueryCount: 0
        ) == false)
    }

    /// The two halves together: owning a Team Library query and typing a term that matches nothing
    /// is a search miss, not an empty account.
    @Test("A Team Library user whose filter matches nothing gets the search miss")
    func aTeamLibraryFilterMissIsASearchMiss() {
        let owns = FavoritesEmptyState.hasAnyFavorite(
            hasQueries: false,
            favoriteTableCount: 0,
            favoriteDatabaseCount: 0,
            teamLibraryQueryCount: 4
        )

        #expect(FavoritesEmptyState.resolve(input(
            hasAnyFavorite: owns,
            hasVisibleContent: false,
            searchText: "zzz"
        )) == .noSearchMatch("zzz"))
    }
}
