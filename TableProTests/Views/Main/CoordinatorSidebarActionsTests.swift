//
//  CoordinatorSidebarActionsTests.swift
//  TableProTests
//
//  Tests for sidebar action guard conditions on MainContentCoordinator.
//

import Foundation
import Testing

@testable import TablePro

@Suite("CoordinatorSidebarActions")
struct CoordinatorSidebarActionsTests {
    // MARK: - Helpers

    @MainActor
    private func makeCoordinator(
        type: DatabaseType = .mysql,
        safeModeLevel: SafeModeLevel = .silent
    ) -> (MainContentCoordinator, QueryTabManager) {
        var connection = TestFixtures.makeConnection(type: type)
        connection.safeModeLevel = safeModeLevel
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
        return (coordinator, tabManager)
    }

    // MARK: - createView

    @Test("createView with readOnly safe mode returns early without crashing")
    @MainActor
    func createViewBlockedByReadOnlySafeMode() {
        let (coordinator, _) = makeCoordinator(safeModeLevel: .readOnly)
        defer { coordinator.teardown() }

        // Should return early due to safeModeLevel.blocksAllWrites
        coordinator.createView()
    }

    @Test("createView does not crash for each database type", arguments: [
        DatabaseType.mysql, .mariadb, .postgresql, .sqlite, .redshift,
        .clickhouse, .mssql, .oracle, .mongodb, .redis, .duckdb,
    ])
    @MainActor
    func createViewDoesNotCrash(type: DatabaseType) {
        let (coordinator, _) = makeCoordinator(type: type)
        defer { coordinator.teardown() }

        // Exercises the switch branch for each type; WindowOpener call
        // is a side effect we can't assert on, but we verify no crash.
        coordinator.createView()
    }

    // MARK: - openImportDialog

    @Test("openImportDialog with readOnly safe mode returns early without crashing")
    @MainActor
    func openImportDialogBlockedByReadOnlySafeMode() {
        let (coordinator, _) = makeCoordinator(safeModeLevel: .readOnly)
        defer { coordinator.teardown() }

        coordinator.openImportDialog()
    }

    @Test("openImportDialog with MongoDB returns early at type guard")
    @MainActor
    func openImportDialogBlockedForMongoDB() {
        let (coordinator, _) = makeCoordinator(type: .mongodb)
        defer { coordinator.teardown() }

        // Hits the MongoDB/Redis guard; shows an alert as side effect
        // but should not crash.
        coordinator.openImportDialog()
    }

    @Test("openImportDialog with Redis returns early at type guard")
    @MainActor
    func openImportDialogBlockedForRedis() {
        let (coordinator, _) = makeCoordinator(type: .redis)
        defer { coordinator.teardown() }

        coordinator.openImportDialog()
    }

    // MARK: - openExportDialog

    @Test("openExportDialog sets activeSheet to exportDialog")
    @MainActor
    func openExportDialogSetsActiveSheet() {
        let (coordinator, _) = makeCoordinator()
        defer { coordinator.teardown() }

        coordinator.openExportDialog()

        #expect(coordinator.activeSheet == .exportDialog)
    }
}
