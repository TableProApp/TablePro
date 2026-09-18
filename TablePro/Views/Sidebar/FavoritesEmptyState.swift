//
//  FavoritesEmptyState.swift
//  TablePro
//

import Foundation

/// Which of the four states the Favorites tab is in.
///
/// The tab used to decide this inline, and read a list emptied by the environment filter as a
/// failed search: `ContentUnavailableView.search(text:)` renders "No Results for “”" over spelling
/// advice for a query the user never typed. A filter miss is a different state with a different
/// cause and gets its own.
internal enum FavoritesEmptyState: Equatable {
    case loading
    case noFavorites
    case noFilterMatch
    case noSearchMatch(String)
    case content

    internal struct Input {
        internal let isInitialLoadComplete: Bool
        internal let hasAnyFavorite: Bool
        internal let hasVisibleContent: Bool
        internal let searchText: String
        internal let isEnvironmentFiltered: Bool

        internal init(
            isInitialLoadComplete: Bool,
            hasAnyFavorite: Bool,
            hasVisibleContent: Bool,
            searchText: String,
            isEnvironmentFiltered: Bool
        ) {
            self.isInitialLoadComplete = isInitialLoadComplete
            self.hasAnyFavorite = hasAnyFavorite
            self.hasVisibleContent = hasVisibleContent
            self.searchText = searchText
            self.isEnvironmentFiltered = isEnvironmentFiltered
        }
    }

    internal static func resolve(_ input: Input) -> FavoritesEmptyState {
        if input.hasVisibleContent { return .content }
        if !input.isInitialLoadComplete && !input.hasAnyFavorite { return .loading }
        if !input.hasAnyFavorite { return .noFavorites }
        if !input.searchText.isEmpty { return .noSearchMatch(input.searchText) }
        if input.isEnvironmentFiltered { return .noFilterMatch }
        return .noFavorites
    }
}
