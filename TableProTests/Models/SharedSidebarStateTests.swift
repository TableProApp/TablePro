//
//  SharedSidebarStateTests.swift
//  TableProTests
//
//  Tests for SharedSidebarState — per-connection shared sidebar state registry.
//  Window-scoped state (selection, search) lives in WindowSidebarState; see
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
}
