//
//  CoordinatorReloadSidebarTests.swift
//  TableProTests
//
//  Tests for MainContentCoordinator.reloadSidebar() —
//  verifies it delegates to sidebarViewModel.forceLoadTables()
//  and is safe when the weak reference is nil.
//

import SwiftUI
import Testing

@testable import TablePro

// MARK: - Mock TableFetcher

/// Tracks fetch calls via a thread-safe counter for verifying forceLoadTables() delegation.
private final class FetchTrackingTableFetcher: TableFetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var _fetchCount = 0
    private var _forceCount = 0

    var fetchCount: Int { lock.withLock { _fetchCount } }
    var forceCount: Int { lock.withLock { _forceCount } }

    func fetchTables(force: Bool) async throws -> [TableInfo] {
        lock.withLock {
            _fetchCount += 1
            if force { _forceCount += 1 }
        }
        return []
    }
}

@Suite("CoordinatorReloadSidebar")
struct CoordinatorReloadSidebarTests {
    @Test("reloadSidebar calls forceLoadTables when sidebarViewModel is set")
    @MainActor
    func callsForceLoadTablesWhenViewModelSet() async {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let tabManager = QueryTabManager()
        let changeManager = DataChangeManager()
        let filterStateManager = FilterStateManager()
        let toolbarState = ConnectionToolbarState()

        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: changeManager,
            filterStateManager: filterStateManager,
            columnVisibilityManager: ColumnVisibilityManager(),
            toolbarState: toolbarState
        )
        defer { coordinator.teardown() }

        var tables: [TableInfo] = []
        var selectedTables: Set<TableInfo> = []
        var pendingTruncates: Set<String> = []
        var pendingDeletes: Set<String> = []
        var tableOperationOptions: [String: TableOperationOptions] = [:]

        let mockFetcher = FetchTrackingTableFetcher()

        let sidebarVM = SidebarViewModel(
            tables: Binding(get: { tables }, set: { tables = $0 }),
            selectedTables: Binding(get: { selectedTables }, set: { selectedTables = $0 }),
            pendingTruncates: Binding(get: { pendingTruncates }, set: { pendingTruncates = $0 }),
            pendingDeletes: Binding(get: { pendingDeletes }, set: { pendingDeletes = $0 }),
            tableOperationOptions: Binding(get: { tableOperationOptions }, set: { tableOperationOptions = $0 }),
            databaseType: .mysql,
            connectionId: connection.id,
            tableFetcher: mockFetcher
        )

        coordinator.sidebarViewModel = sidebarVM

        coordinator.reloadSidebar()

        // forceLoadTables triggers an async Task internally, give it time to execute
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(mockFetcher.fetchCount > 0)
        #expect(mockFetcher.forceCount > 0)
    }

    @Test("reloadSidebar is safe when sidebarViewModel is nil")
    @MainActor
    func safeWhenViewModelNil() {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let tabManager = QueryTabManager()
        let changeManager = DataChangeManager()
        let filterStateManager = FilterStateManager()
        let toolbarState = ConnectionToolbarState()

        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: changeManager,
            filterStateManager: filterStateManager,
            columnVisibilityManager: ColumnVisibilityManager(),
            toolbarState: toolbarState
        )
        defer { coordinator.teardown() }

        #expect(coordinator.sidebarViewModel == nil)

        // Should not crash
        coordinator.reloadSidebar()
    }

    @Test("reloadSidebar is safe after sidebarViewModel is deallocated")
    @MainActor
    func safeAfterViewModelDeallocated() {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let tabManager = QueryTabManager()
        let changeManager = DataChangeManager()
        let filterStateManager = FilterStateManager()
        let toolbarState = ConnectionToolbarState()

        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: changeManager,
            filterStateManager: filterStateManager,
            columnVisibilityManager: ColumnVisibilityManager(),
            toolbarState: toolbarState
        )
        defer { coordinator.teardown() }

        var tables: [TableInfo] = []
        var selectedTables: Set<TableInfo> = []
        var pendingTruncates: Set<String> = []
        var pendingDeletes: Set<String> = []
        var tableOperationOptions: [String: TableOperationOptions] = [:]

        // Create and assign in a local scope so it gets deallocated
        do {
            let sidebarVM = SidebarViewModel(
                tables: Binding(get: { tables }, set: { tables = $0 }),
                selectedTables: Binding(get: { selectedTables }, set: { selectedTables = $0 }),
                pendingTruncates: Binding(get: { pendingTruncates }, set: { pendingTruncates = $0 }),
                pendingDeletes: Binding(get: { pendingDeletes }, set: { pendingDeletes = $0 }),
                tableOperationOptions: Binding(get: { tableOperationOptions }, set: { tableOperationOptions = $0 }),
                databaseType: .mysql,
                connectionId: connection.id
            )
            coordinator.sidebarViewModel = sidebarVM
        }

        // Weak reference should be nil after the local scope ends
        #expect(coordinator.sidebarViewModel == nil)

        // Should not crash
        coordinator.reloadSidebar()
    }
}
