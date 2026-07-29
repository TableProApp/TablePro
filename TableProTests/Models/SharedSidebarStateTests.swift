//
//  SharedSidebarStateTests.swift
//  TableProTests
//
//  Tests for SharedSidebarState — per-connection shared sidebar state registry.
//  Window-scoped state (table selection) lives in WindowSidebarState; see
//  WindowSidebarStateTests.
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("SharedSidebarState")
struct SharedSidebarStateTests {

    // MARK: - Registry

    @Test("forConnection returns same instance for same UUID")
    @MainActor
    func sameInstanceForSameId() {
        let id = UUID()
        let a = SharedSidebarState.forConnection(id)
        let b = SharedSidebarState.forConnection(id)
        #expect(a === b)
        SharedSidebarState.removeConnection(id)
    }

    @Test("forConnection returns different instances for different UUIDs")
    @MainActor
    func differentInstanceForDifferentId() {
        let id1 = UUID()
        let id2 = UUID()
        let a = SharedSidebarState.forConnection(id1)
        let b = SharedSidebarState.forConnection(id2)
        #expect(a !== b)
        SharedSidebarState.removeConnection(id1)
        SharedSidebarState.removeConnection(id2)
    }

    @Test("removeConnection removes from registry — next call creates new instance")
    @MainActor
    func removeCreatesNewInstance() {
        let id = UUID()
        let a = SharedSidebarState.forConnection(id)
        SharedSidebarState.removeConnection(id)
        let b = SharedSidebarState.forConnection(id)
        #expect(a !== b)
        SharedSidebarState.removeConnection(id)
    }

    @Test("removeConnection for unknown ID does not crash")
    @MainActor
    func removeUnknownIdNoCrash() {
        SharedSidebarState.removeConnection(UUID())
    }

    // MARK: - Sidebar Tab Persistence

    @Test("selectedSidebarTab persists across registry lookups for same connection")
    @MainActor
    func selectedSidebarTabPersists() {
        let id = UUID()
        let a = SharedSidebarState.forConnection(id)
        a.selectedSidebarTab = .favorites
        let b = SharedSidebarState.forConnection(id)
        #expect(b.selectedSidebarTab == .favorites)
        SharedSidebarState.removeConnection(id)
    }

    // MARK: - Filter Text

    @Test("searchText persists across registry lookups for same connection")
    @MainActor
    func searchTextPersists() {
        let id = UUID()
        let a = SharedSidebarState.forConnection(id)
        a.searchText = "users"
        let b = SharedSidebarState.forConnection(id)
        #expect(b.searchText == "users")
        SharedSidebarState.removeConnection(id)
    }

    @Test("favoritesSearchText persists across registry lookups for same connection")
    @MainActor
    func favoritesSearchTextPersists() {
        let id = UUID()
        let a = SharedSidebarState.forConnection(id)
        a.favoritesSearchText = "daily"
        let b = SharedSidebarState.forConnection(id)
        #expect(b.favoritesSearchText == "daily")
        SharedSidebarState.removeConnection(id)
    }

    @Test("filter text is independent across different connections")
    @MainActor
    func filterTextIndependentAcrossConnections() {
        let id1 = UUID()
        let id2 = UUID()
        let a = SharedSidebarState.forConnection(id1)
        let b = SharedSidebarState.forConnection(id2)
        a.searchText = "orders"
        #expect(b.searchText.isEmpty)
        SharedSidebarState.removeConnection(id1)
        SharedSidebarState.removeConnection(id2)
    }

    // MARK: - Favorite Selection

    @Test("selectedFavorite persists across registry lookups for same connection")
    @MainActor
    func selectedFavoritePersists() {
        let id = UUID()
        let selection = FavoriteSelection.node(id: "fav-\(id.uuidString)")
        let a = SharedSidebarState.forConnection(id)
        a.selectedFavorite = selection
        let b = SharedSidebarState.forConnection(id)
        #expect(b.selectedFavorite == selection)
        a.selectedFavorite = nil
        SharedSidebarState.removeConnection(id)
    }
}
