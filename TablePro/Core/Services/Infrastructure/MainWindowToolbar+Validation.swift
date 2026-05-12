//
//  MainWindowToolbar+Validation.swift
//  TablePro
//

import AppKit
import TableProPluginKit

extension MainWindowToolbar: NSToolbarItemValidation {
    struct ValidationContext {
        let connected: Bool
        let isTableTab: Bool
        let hasPendingChanges: Bool
        let hasDataPendingChanges: Bool
        let blocksAllWrites: Bool
        let fileBased: Bool
        let supportsDatabaseSwitching: Bool
        let supportsImport: Bool
        let supportsServerDashboard: Bool
    }

    static func isEnabled(itemIdentifier: NSToolbarItem.Identifier, context: ValidationContext) -> Bool {
        switch itemIdentifier {
        case Self.connection, Self.history:
            return true
        case Self.database:
            return context.connected && !context.fileBased && context.supportsDatabaseSwitching
        case Self.refresh, Self.quickSwitcher, Self.newTab, Self.exportTables:
            return context.connected
        case Self.saveChanges:
            return context.hasPendingChanges && context.connected && !context.blocksAllWrites
        case Self.previewSQL:
            return context.hasDataPendingChanges && context.connected
        case Self.results:
            return context.connected && !context.isTableTab
        case Self.dashboard:
            return context.connected && context.supportsServerDashboard
        case Self.importTables:
            return context.connected && !context.blocksAllWrites && context.supportsImport
        default:
            return true
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard let state = coordinator?.toolbarState else { return false }
        let context = ValidationContext(
            connected: state.connectionState == .connected,
            isTableTab: state.isTableTab,
            hasPendingChanges: state.hasPendingChanges,
            hasDataPendingChanges: state.hasDataPendingChanges,
            blocksAllWrites: state.safeModeLevel.blocksAllWrites,
            fileBased: PluginManager.shared.connectionMode(for: state.databaseType) == .fileBased,
            supportsDatabaseSwitching: PluginManager.shared.supportsDatabaseSwitching(for: state.databaseType),
            supportsImport: PluginManager.shared.supportsImport(for: state.databaseType),
            supportsServerDashboard: coordinator?.commandActions?.supportsServerDashboard ?? false
        )
        return Self.isEnabled(itemIdentifier: item.itemIdentifier, context: context)
    }
}
