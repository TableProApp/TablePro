//
//  SharedSidebarStateTests.swift
//  TableProTests
//
//  Tests for SharedSidebarState — per-connection shared sidebar state registry.
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

    // MARK: - Default State

    @Test("New instance has empty selectedTables")
    @MainActor
    func defaultSelectedTablesEmpty() {
        let state = SharedSidebarState()
        #expect(state.selectedTables.isEmpty)
    }

    @Test("New instance has empty searchText")
    @MainActor
    func defaultSearchTextEmpty() {
        let state = SharedSidebarState()
        #expect(state.searchText.isEmpty)
    }

    // MARK: - State Mutation

    @Test("Setting selectedTables persists")
    @MainActor
    func selectedTablesPersists() {
        let state = SharedSidebarState()
        let table = TestFixtures.makeTableInfo(name: "users")
        state.selectedTables = [table]
        #expect(state.selectedTables.count == 1)
        #expect(state.selectedTables.first?.name == "users")
    }

    @Test("Setting searchText persists")
    @MainActor
    func searchTextPersists() {
        let state = SharedSidebarState()
        state.searchText = "user"
        #expect(state.searchText == "user")
    }

    // MARK: - Shared Reference Semantics

    @Test("Changes via one reference are visible through another")
    @MainActor
    func sharedReferenceSemantics() {
        let id = UUID()
        let a = SharedSidebarState.forConnection(id)
        let b = SharedSidebarState.forConnection(id)
        let table = TestFixtures.makeTableInfo(name: "orders")
        a.selectedTables = [table]
        #expect(b.selectedTables.count == 1)
        #expect(b.selectedTables.first?.name == "orders")
        a.searchText = "ord"
        #expect(b.searchText == "ord")
        SharedSidebarState.removeConnection(id)
    }

    @Test("Clearing selectedTables is visible through shared reference")
    @MainActor
    func clearingSelectionShared() {
        let id = UUID()
        let a = SharedSidebarState.forConnection(id)
        let b = SharedSidebarState.forConnection(id)
        a.selectedTables = [TestFixtures.makeTableInfo(name: "users")]
        #expect(!b.selectedTables.isEmpty)
        a.selectedTables = []
        #expect(b.selectedTables.isEmpty)
        SharedSidebarState.removeConnection(id)
    }

    // MARK: - Disconnect Cleanup

    @Test("removeConnection clears state for that connection")
    @MainActor
    func removeConnectionClearsState() {
        let id = UUID()
        let state = SharedSidebarState.forConnection(id)
        state.selectedTables = [TestFixtures.makeTableInfo(name: "users")]
        state.searchText = "us"
        SharedSidebarState.removeConnection(id)
        // New instance should have clean state
        let fresh = SharedSidebarState.forConnection(id)
        #expect(fresh.selectedTables.isEmpty)
        #expect(fresh.searchText.isEmpty)
        SharedSidebarState.removeConnection(id)
    }

    @Test("removeConnection does not affect other connections")
    @MainActor
    func removeDoesNotAffectOthers() {
        let id1 = UUID()
        let id2 = UUID()
        let state1 = SharedSidebarState.forConnection(id1)
        let state2 = SharedSidebarState.forConnection(id2)
        state1.selectedTables = [TestFixtures.makeTableInfo(name: "a")]
        state2.selectedTables = [TestFixtures.makeTableInfo(name: "b")]
        SharedSidebarState.removeConnection(id1)
        #expect(state2.selectedTables.first?.name == "b")
        SharedSidebarState.removeConnection(id2)
    }
}
