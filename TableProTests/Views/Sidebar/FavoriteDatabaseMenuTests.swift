//
//  FavoriteDatabaseMenuTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("FavoriteDatabaseMenu")
struct FavoriteDatabaseMenuTests {
    @Test("One database that is not a favorite offers Add to Favorites with nothing checked")
    func singleNonFavorite() {
        let state = FavoriteDatabaseSelectionState(environments: [nil])

        #expect(FavoriteDatabaseMenu.submenuTitle(for: state) == String(localized: "Add to Favorites"))
        #expect(!state.hasFavorite)
        #expect(FavoriteDatabaseMenu.environmentItems(for: state).allSatisfy { !$0.isOn })
    }

    @Test("One favorite offers Environment with its own tag checked")
    func singleFavorite() {
        let state = FavoriteDatabaseSelectionState(environments: [.production])

        #expect(FavoriteDatabaseMenu.submenuTitle(for: state) == String(localized: "Environment"))
        #expect(state.hasFavorite)
        let checked = FavoriteDatabaseMenu.environmentItems(for: state).filter(\.isOn)
        #expect(checked.map(\.environment) == [.production])
    }

    @Test("A selection that agrees on its tag keeps the checkmark")
    func uniformSelection() {
        let state = FavoriteDatabaseSelectionState(environments: [.testing, .testing])

        #expect(FavoriteDatabaseMenu.submenuTitle(for: state) == String(localized: "Environment"))
        #expect(FavoriteDatabaseMenu.environmentItems(for: state).filter(\.isOn).map(\.environment) == [.testing])
    }

    /// Checking one option would claim every selected database carries it.
    @Test("A selection that disagrees on its tag checks nothing")
    func mixedEnvironments() {
        let state = FavoriteDatabaseSelectionState(environments: [.testing, .production])

        #expect(FavoriteDatabaseMenu.submenuTitle(for: state) == String(localized: "Environment"))
        #expect(FavoriteDatabaseMenu.environmentItems(for: state).allSatisfy { !$0.isOn })
    }

    @Test("A selection where only some are favorites still offers Add to Favorites")
    func partiallyFavorite() {
        let state = FavoriteDatabaseSelectionState(environments: [.production, nil])

        #expect(FavoriteDatabaseMenu.submenuTitle(for: state) == String(localized: "Add to Favorites"))
        #expect(state.hasFavorite)
        #expect(!state.isEntirelyFavorite)
        #expect(FavoriteDatabaseMenu.environmentItems(for: state).allSatisfy { !$0.isOn })
    }

    @Test("An empty selection has nothing to offer")
    func emptySelection() {
        let state = FavoriteDatabaseSelectionState(environments: [])

        #expect(state.isEmpty)
        #expect(!state.hasFavorite)
        #expect(!state.isEntirelyFavorite)
    }

    @Test("Every environment gets an item, in declaration order")
    func coversEveryEnvironment() {
        let items = FavoriteDatabaseMenu.environmentItems(
            for: FavoriteDatabaseSelectionState(environments: [nil])
        )

        #expect(items.map(\.environment) == FavoriteDatabaseEnvironment.allCases)
        #expect(items.map(\.title) == FavoriteDatabaseEnvironment.allCases.map(\.title))
    }

    /// One bucket, one name. The group header, the filter popup and both menus used to disagree,
    /// showing "No Environment" beside a group labelled "Unassigned".
    @Test("The unassigned bucket has exactly one name everywhere")
    func unassignedHasOneName() {
        let menuTitle = FavoriteDatabaseMenu.environmentItems(
            for: FavoriteDatabaseSelectionState(environments: [nil])
        )
        .first { $0.environment == .unassigned }?
        .title

        #expect(menuTitle == FavoriteDatabaseEnvironment.unassigned.title)
        #expect(menuTitle == FavoriteDatabaseEnvironmentFilter.unassigned.title)
    }
}
