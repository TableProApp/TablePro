//
//  FavoriteDatabaseMenu.swift
//  TablePro
//

import Foundation

/// What the favorite items look like for one right-click, as values.
///
/// A click can carry several databases, and they need not agree: some may be favorites already, and
/// the ones that are may be tagged differently. Resolving that once here keeps the object tree, the
/// database switcher, the Favorites tab and the Database menu showing the same thing.
internal struct FavoriteDatabaseSelectionState: Equatable {
    internal let targetCount: Int
    internal let favoriteCount: Int
    /// The environment every favorite in the selection shares, or nil when they disagree.
    internal let sharedEnvironment: FavoriteDatabaseEnvironment?

    internal init(environments: [FavoriteDatabaseEnvironment?]) {
        targetCount = environments.count
        let assigned = environments.compactMap { $0 }
        favoriteCount = assigned.count
        let distinct = Set(assigned)
        sharedEnvironment = distinct.count == 1 ? distinct.first : nil
    }

    internal var isEmpty: Bool { targetCount == 0 }
    /// Retagging rather than adding, so the submenu names the attribute instead of the action.
    internal var isEntirelyFavorite: Bool { favoriteCount == targetCount && targetCount > 0 }
    internal var hasFavorite: Bool { favoriteCount > 0 }
}

internal enum FavoriteDatabaseMenu {
    internal struct EnvironmentItem: Equatable {
        internal let environment: FavoriteDatabaseEnvironment
        internal let title: String
        internal let isOn: Bool
    }

    internal static func submenuTitle(for state: FavoriteDatabaseSelectionState) -> String {
        state.isEntirelyFavorite
            ? String(localized: "Environment")
            : String(localized: "Add to Favorites")
    }

    internal static var removeTitle: String {
        String(localized: "Remove from Favorites")
    }

    internal static func environmentItems(for state: FavoriteDatabaseSelectionState) -> [EnvironmentItem] {
        FavoriteDatabaseEnvironment.allCases.map { environment in
            EnvironmentItem(
                environment: environment,
                title: environment.title,
                isOn: state.isEntirelyFavorite && state.sharedEnvironment == environment
            )
        }
    }
}
