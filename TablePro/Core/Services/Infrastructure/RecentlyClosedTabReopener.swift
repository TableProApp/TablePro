import Foundation

/// Brings a closed tab back into the window showing its connection.
///
/// The history entry outlives every step that can still fail. It is read rather than taken, and let
/// go only once the tab is in a tab list: taking it first is what turned a reopen that opened
/// nothing into a closed tab lost for good.
@MainActor
internal enum RecentlyClosedTabReopener {
    internal typealias Adoption = (
        _ tab: QueryTab,
        _ connectionId: UUID,
        _ isStillClosed: @escaping () -> Bool,
        _ onAdopted: @escaping () -> Void
    ) -> Void

    internal static func reopenMostRecent() {
        guard let entry = RecentlyClosedTabStore.shared.mostRecentEntry else { return }
        reopen(id: entry.id)
    }

    /// A connection no window hosts has to connect before it has anywhere to put the tab, so the
    /// router connects it and hands the entry back through `reopen(_:from:adopt:)`.
    internal static func reopen(id: UUID) {
        guard let entry = RecentlyClosedTabStore.shared.restorableEntry(id: id) else { return }
        guard WindowManager.shared.hasOpenWindow(for: entry.connectionId) else {
            Task { await LaunchIntentRouter.shared.route(.reopenClosedTab(entry)) }
            return
        }
        reopen(entry)
    }

    internal static func reopen(
        _ entry: RecentlyClosedTabEntry,
        from store: RecentlyClosedTabStore = .shared,
        adopt: Adoption = { tab, connectionId, isStillClosed, onAdopted in
            WindowManager.shared.reopen(
                tab,
                connectionId: connectionId,
                isStillClosed: isStillClosed,
                onAdopted: onAdopted
            )
        }
    ) {
        let entryId = entry.id
        adopt(
            makeTab(for: entry),
            entry.connectionId,
            { store.containsEntry(id: entryId) },
            { store.discard(id: entryId) }
        )
    }

    private static func makeTab(for entry: RecentlyClosedTabEntry) -> QueryTab {
        var tab = QueryTab(
            from: entry.tab,
            defaultPageSize: AppSettingsManager.shared.dataGrid.defaultPageSize
        )
        FileTabBaseline.hydrate(&tab)
        return tab
    }
}
