import AppKit
import Foundation

/// Brings a closed tab back into a native window tab. Reopening reuses the restoration path that
/// cold launch already uses, so a reopened table tab recovers its filters, sort, and column
/// layout instead of reimplementing that here.
@MainActor
internal enum RecentlyClosedTabReopener {
    internal static func reopenMostRecent() {
        guard let entry = RecentlyClosedTabStore.shared.mostRecentEntry else { return }
        reopen(id: entry.id)
    }

    internal static func reopen(id: UUID) {
        guard let entry = RecentlyClosedTabStore.shared.consume(id: id) else { return }

        // Closing the last tab of the last window leaves the window standing but empty. Reopening
        // into a new window tab there would strand that empty tab alongside the restored one, so
        // the empty window is filled in place, matching how New Tab reuses it.
        if let coordinator = emptyWindowCoordinator(for: entry.connectionId) {
            restore(entry, into: coordinator)
            return
        }

        guard WindowManager.shared.hasOpenWindow(for: entry.connectionId) else {
            Task { await LaunchIntentRouter.shared.route(.reopenClosedTab(entry)) }
            return
        }

        openWindowTab(for: entry)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func emptyWindowCoordinator(for connectionId: UUID) -> MainContentCoordinator? {
        let empty = MainContentCoordinator.allActiveCoordinators().filter {
            $0.connectionId == connectionId && $0.tabManager.tabs.isEmpty
        }
        return empty.first { $0.contentWindow?.isKeyWindow == true } ?? empty.first
    }

    private static func restore(_ entry: RecentlyClosedTabEntry, into coordinator: MainContentCoordinator) {
        let tab = makeTab(for: entry)
        coordinator.tabManager.adoptTab(tab, claimFocus: tab.tabType == .query)

        if tab.tabType == .table, let tableName = tab.tableContext.tableName {
            coordinator.restoreLastHiddenColumnsForTable()
            coordinator.restoreFiltersForTable(tableName)
            coordinator.lazyLoadCurrentTabIfNeeded(trigger: .restore)
        }

        coordinator.contentWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func makeTab(for entry: RecentlyClosedTabEntry) -> QueryTab {
        QueryTab(
            from: entry.tab,
            defaultPageSize: AppSettingsManager.shared.dataGrid.defaultPageSize
        )
    }

    internal static func openWindowTab(for entry: RecentlyClosedTabEntry) {
        let tab = makeTab(for: entry)
        let payload = EditorTabPayload(
            connectionId: entry.connectionId,
            tabType: tab.tabType,
            tableName: tab.tableContext.tableName,
            databaseName: tab.tableContext.databaseName,
            schemaName: tab.tableContext.schemaName,
            isView: tab.tableContext.isView,
            skipAutoExecute: true,
            sourceFileURL: tab.content.sourceFileURL,
            erDiagramSchemaKey: tab.display.erDiagramSchemaKey,
            tabTitle: tab.title,
            intent: .restoreOrDefault
        )
        RestorationGroupRegistry.register(
            .init(tabs: [tab], selectedTabId: tab.id, loadTiming: .immediate),
            for: payload.id
        )
        WindowManager.shared.openTab(payload: payload)
    }
}
