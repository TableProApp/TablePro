//
//  FavoritesEmptyStateTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("FavoritesEmptyState")
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
}
