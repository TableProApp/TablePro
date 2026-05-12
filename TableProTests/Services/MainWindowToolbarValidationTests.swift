//
//  MainWindowToolbarValidationTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct MainWindowToolbarValidationTests {
    private func makeContext(
        connected: Bool = true,
        isTableTab: Bool = false,
        hasPendingChanges: Bool = false,
        hasDataPendingChanges: Bool = false,
        blocksAllWrites: Bool = false,
        fileBased: Bool = false,
        supportsDatabaseSwitching: Bool = true,
        supportsImport: Bool = true,
        supportsServerDashboard: Bool = true
    ) -> MainWindowToolbar.ValidationContext {
        MainWindowToolbar.ValidationContext(
            connected: connected,
            isTableTab: isTableTab,
            hasPendingChanges: hasPendingChanges,
            hasDataPendingChanges: hasDataPendingChanges,
            blocksAllWrites: blocksAllWrites,
            fileBased: fileBased,
            supportsDatabaseSwitching: supportsDatabaseSwitching,
            supportsImport: supportsImport,
            supportsServerDashboard: supportsServerDashboard
        )
    }

    @Test("Save Changes disabled when safe mode blocks writes")
    func saveChangesBlockedBySafeMode() {
        let context = makeContext(
            connected: true,
            hasPendingChanges: true,
            blocksAllWrites: true
        )
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.saveChanges, context: context) == false)
    }

    @Test("Save Changes disabled when no pending changes")
    func saveChangesDisabledWhenNoPending() {
        let context = makeContext(connected: true, hasPendingChanges: false)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.saveChanges, context: context) == false)
    }

    @Test("Save Changes enabled when pending changes, connected, writes allowed")
    func saveChangesEnabledHappyPath() {
        let context = makeContext(connected: true, hasPendingChanges: true, blocksAllWrites: false)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.saveChanges, context: context) == true)
    }

    @Test("Save Changes disabled when disconnected")
    func saveChangesDisabledWhenDisconnected() {
        let context = makeContext(connected: false, hasPendingChanges: true)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.saveChanges, context: context) == false)
    }

    @Test("Results enabled only off table tabs")
    func resultsDisabledOnTableTab() {
        let onTable = makeContext(connected: true, isTableTab: true)
        let onQuery = makeContext(connected: true, isTableTab: false)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.results, context: onTable) == false)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.results, context: onQuery) == true)
    }

    @Test("Database switcher disabled for file-based connections")
    func databaseDisabledForFileBased() {
        let fileBased = makeContext(connected: true, fileBased: true)
        let networked = makeContext(connected: true, fileBased: false)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.database, context: fileBased) == false)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.database, context: networked) == true)
    }

    @Test("Database switcher requires plugin support")
    func databaseRequiresPluginSupport() {
        let unsupported = makeContext(connected: true, supportsDatabaseSwitching: false)
        let supported = makeContext(connected: true, supportsDatabaseSwitching: true)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.database, context: unsupported) == false)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.database, context: supported) == true)
    }

    @Test("Import disabled when safe mode blocks writes")
    func importBlockedBySafeMode() {
        let context = makeContext(connected: true, blocksAllWrites: true, supportsImport: true)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.importTables, context: context) == false)
    }

    @Test("Import requires plugin support")
    func importRequiresPluginSupport() {
        let context = makeContext(connected: true, supportsImport: false)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.importTables, context: context) == false)
    }

    @Test("Export requires only connection")
    func exportRequiresConnection() {
        let connected = makeContext(connected: true)
        let disconnected = makeContext(connected: false)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.exportTables, context: connected) == true)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.exportTables, context: disconnected) == false)
    }

    @Test("Preview SQL requires data pending changes and connection")
    func previewSQLRequirements() {
        let neither = makeContext(connected: false, hasDataPendingChanges: false)
        let onlyConnected = makeContext(connected: true, hasDataPendingChanges: false)
        let onlyPending = makeContext(connected: false, hasDataPendingChanges: true)
        let both = makeContext(connected: true, hasDataPendingChanges: true)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.previewSQL, context: neither) == false)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.previewSQL, context: onlyConnected) == false)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.previewSQL, context: onlyPending) == false)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.previewSQL, context: both) == true)
    }

    @Test("Dashboard requires plugin support and connection")
    func dashboardRequirements() {
        let unsupported = makeContext(connected: true, supportsServerDashboard: false)
        let disconnected = makeContext(connected: false, supportsServerDashboard: true)
        let happy = makeContext(connected: true, supportsServerDashboard: true)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.dashboard, context: unsupported) == false)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.dashboard, context: disconnected) == false)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.dashboard, context: happy) == true)
    }

    @Test("Connection and History stay enabled regardless of connection state")
    func alwaysEnabledItems() {
        let disconnected = makeContext(connected: false)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.connection, context: disconnected) == true)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.history, context: disconnected) == true)
    }

    @Test("Unknown identifier defaults to enabled")
    func unknownIdentifierEnabled() {
        let context = makeContext(connected: false)
        let unknown = NSToolbarItem.Identifier("com.test.unknown")
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: unknown, context: context) == true)
    }
}
