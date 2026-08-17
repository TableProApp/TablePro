//
//  MainWindowToolbar+Validation.swift
//  TablePro
//

import AppKit
import TableProPluginKit

extension MainWindowToolbar: NSToolbarItemValidation {
    struct ValidationContext {
        /// True whenever the session is alive, which includes a query in flight. A running
        /// query is not a reason to disable Refresh or New Tab, and the menu bar already
        /// derives its own `isConnected` from the window phase rather than from execution.
        let connected: Bool
        let isTableTab: Bool
        let hasPendingChanges: Bool
        let hasDataPendingChanges: Bool
        let blocksAllWrites: Bool
        let fileBased: Bool
        let supportsContainerSwitching: Bool
        let supportsImport: Bool
        let supportsServerDashboard: Bool
    }

    /// Listed exhaustively so a new state has to choose a side instead of inheriting "alive".
    static func hasLiveSession(_ state: ToolbarConnectionState) -> Bool {
        switch state {
        case .connected, .executing:
            return true
        case .disconnected, .connecting, .error:
            return false
        }
    }

    static func isEnabled(itemIdentifier: NSToolbarItem.Identifier, context: ValidationContext) -> Bool {
        switch itemIdentifier {
        case Self.connection, Self.history:
            return true
        case Self.database:
            return context.connected && !context.fileBased && context.supportsContainerSwitching
        case Self.refresh, Self.quickSwitcher, Self.newTab, Self.exportTables, Self.sidebarToggle:
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

    func validationContext() -> ValidationContext? {
        guard let state = coordinator?.toolbarState else { return nil }
        return ValidationContext(
            connected: Self.hasLiveSession(state.connectionState),
            isTableTab: state.isTableTab,
            hasPendingChanges: state.hasPendingChanges,
            hasDataPendingChanges: state.hasDataPendingChanges,
            blocksAllWrites: state.safeModeLevel.blocksAllWrites,
            fileBased: PluginManager.shared.connectionMode(for: state.databaseType) == .fileBased,
            supportsContainerSwitching: PluginManager.shared.supportsContainerSwitching(for: state.databaseType),
            supportsImport: PluginManager.shared.supportsImport(for: state.databaseType),
            supportsServerDashboard: coordinator?.commandActions?.supportsServerDashboard ?? false
        )
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard let context = validationContext() else { return false }
        return Self.isEnabled(itemIdentifier: item.itemIdentifier, context: context)
    }
}

/// AppKit validates toolbar overflow entries as menu items rather than visible toolbar items.
/// Keep their state aligned with the predicates used by `validateToolbarItem(_:)`.
extension MainWindowToolbar: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let itemIdentifier: NSToolbarItem.Identifier
        switch menuItem.action {
        case #selector(performSaveChanges(_:)):
            itemIdentifier = Self.saveChanges
        case #selector(performPreviewSQL(_:)):
            itemIdentifier = Self.previewSQL
        case #selector(performImportFormat(_:)):
            itemIdentifier = Self.importTables
        default:
            return true
        }
        guard let context = validationContext() else { return false }
        return Self.isEnabled(itemIdentifier: itemIdentifier, context: context)
    }
}
