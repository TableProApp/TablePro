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

        guard WindowManager.shared.hasOpenWindow(for: entry.connectionId) else {
            Task { await LaunchIntentRouter.shared.route(.reopenClosedTab(entry)) }
            return
        }

        openWindowTab(for: entry)
        NSApp.activate(ignoringOtherApps: true)
    }

    internal static func openWindowTab(for entry: RecentlyClosedTabEntry) {
        let tab = QueryTab(
            from: entry.tab,
            defaultPageSize: AppSettingsManager.shared.dataGrid.defaultPageSize
        )
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
