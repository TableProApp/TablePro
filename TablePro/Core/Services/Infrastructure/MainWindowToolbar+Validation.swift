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
        let canAddRow: Bool
        let canRestorePreviousValues: Bool
        let hasPendingChanges: Bool
        let hasDataPendingChanges: Bool
        let blocksAllWrites: Bool
        let fileBased: Bool
        let supportsContainerSwitching: Bool
        let supportsImport: Bool
        let supportsServerDashboard: Bool
        let canNavigateBack: Bool
        let canNavigateForward: Bool
    }

    /// Listed exhaustively so a new state has to choose a side instead of inheriting "alive".
    ///
    /// `.connecting` counts because the health monitor writes it on every reconnect attempt, and
    /// the window keeps showing the session's tabs and rows throughout. Graying the whole toolbar
    /// out for the length of a backoff would take Sidebar Toggle with it.
    static func hasLiveSession(_ state: ToolbarConnectionState) -> Bool {
        switch state {
        case .connected, .connecting:
            return true
        case .disconnected, .error:
            return false
        }
    }

    static func isEnabled(itemIdentifier: NSToolbarItem.Identifier, context: ValidationContext) -> Bool {
        switch itemIdentifier {
        case Self.connection, Self.history:
            return true
        case Self.assistant:
            /// The View menu command already gates on the window showing content. Without the same
            /// gate here the button stays live over a disconnected session and uncollapses the
            /// assistant beside a connection that cannot answer.
            return context.connected && AppSettingsManager.shared.ai.enabled
        case Self.database:
            return context.connected && !context.fileBased && context.supportsContainerSwitching
        case Self.safeMode:
            /// Safe mode is what stands between a stray keystroke and a live table, so the control
            /// that sets it answers for as long as the session does. A window with no session has
            /// nothing to protect and nothing to write it to.
            return context.connected
        case Self.refresh, Self.quickSwitcher, Self.newTab, Self.exportTables, Self.sidebarToggle:
            return context.connected
        case Self.addRow:
            return context.connected && context.canAddRow
        case Self.restorePreviousValues:
            return context.connected && context.canRestorePreviousValues
        case Self.navigateBack:
            return context.connected && context.canNavigateBack
        case Self.navigateForward:
            return context.connected && context.canNavigateForward
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
            canAddRow: coordinator?.canAddRow ?? false,
            canRestorePreviousValues: coordinator?.canRewindSelectedTab ?? false,
            hasPendingChanges: state.hasPendingChanges,
            hasDataPendingChanges: state.hasDataPendingChanges,
            blocksAllWrites: state.safeModeLevel.blocksAllWrites,
            fileBased: PluginManager.shared.connectionMode(for: state.databaseType) == .fileBased,
            supportsContainerSwitching: PluginManager.shared.supportsContainerSwitching(for: state.databaseType),
            supportsImport: PluginManager.shared.supportsImport(for: state.databaseType),
            supportsServerDashboard: coordinator?.commandActions?.supportsServerDashboard ?? false,
            canNavigateBack: coordinator?.canNavigateBack ?? false,
            canNavigateForward: coordinator?.canNavigateForward ?? false
        )
    }

    /// Switch Connection is the window's, so it answers before a subject is required. Every other
    /// item here needs the coordinator that presents it, and enabling one of those without a
    /// subject would leave a live-looking button that does nothing, so no subject still disables
    /// the rest of the toolbar.
    ///
    /// The sidebar item is not an exception, however window-owned the sidebar itself now is: it is
    /// the Tables/Favorites segmented control, `sidebarSegmentChanged` reaches
    /// `coordinator?.splitViewController`, and the tab it selects is per-connection state that a
    /// window with no session has nowhere to write. Show/Hide Sidebar is the command that answers
    /// in every phase, and it lives in the View menu and on the divider rather than here.
    static func isWindowScoped(_ itemIdentifier: NSToolbarItem.Identifier) -> Bool {
        itemIdentifier == Self.connection
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        if Self.isWindowScoped(item.itemIdentifier) { return true }
        guard let context = validationContext() else { return false }
        return Self.isEnabled(itemIdentifier: item.itemIdentifier, context: context)
    }
}

/// AppKit validates toolbar overflow entries as menu items rather than visible toolbar items, so
/// `validateToolbarItem(_:)` never sees them and every entry it does not answer for stays enabled.
/// A hand-written selector list here only covered three of the twelve actions, which left Refresh,
/// New Tab, Open Quickly, Export, Database, Results and Dashboard live in the overflow menu of a
/// narrow window while the same buttons were disabled on a wide one, and clicking one did nothing.
/// The mapping now comes from the factory that built the item, so it cannot fall behind again.
extension MainWindowToolbar: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let itemIdentifier = itemIdentifier(forMenuFormAction: menuItem.action) else { return true }
        if Self.isWindowScoped(itemIdentifier) { return true }
        guard let context = validationContext() else { return false }
        return Self.isEnabled(itemIdentifier: itemIdentifier, context: context)
    }
}
