//
//  TableRowsRefreshPlan.swift
//  TablePro
//

import Foundation

/// Which table tabs a change to their table leaves holding old rows, and what the selected one does
/// about it now.
///
/// Every addressed tab is marked stale and keeps its rows. A background tab reloads when it is next
/// shown. The selected tab reloads at once only when nothing of the user's is in the way: a change
/// made somewhere else never commits a half-typed cell and never asks to discard edits. A load
/// already running is left to finish only when it reads what the change wrote; one that claimed the
/// tab before the change, or chose its metadata before a definition change, is started again,
/// since its result is out of date the moment it lands. A selected tab left marked reloads once
/// what stood in the way is gone: its cell overlay closes, or its edits are saved, undone or
/// discarded.
struct TableRowsRefreshPlan: Equatable {
    enum SelectedTabAction: Equatable {
        case noReload
        case reloadNow
        case reloadBehindStructure
    }

    /// What is running on the selected tab when the change lands.
    enum SelectedTabLoad: Equatable {
        case idle
        /// A load is scheduled and has not claimed the tab yet, so it reads the table as it is now
        /// and sees the mark when it chooses its metadata.
        case scheduled
        /// A query claimed the tab at this instant.
        case running(startedAt: ContinuousClock.Instant)
        /// Work that extends the rows already on screen, such as Fetch All, and owns no result.
        case extending
    }

    /// What the tab value alone cannot say about the selected tab.
    struct SelectedTabState: Equatable {
        let id: UUID
        let holdsEdits: Bool
        let load: SelectedTabLoad
    }

    let staleTabIds: [UUID]
    let selectedTabAction: SelectedTabAction

    init(
        tabs: [QueryTab],
        selectedTab: SelectedTabState?,
        change: TableFreshness.Change,
        excludingTabId: UUID? = nil,
        where isAddressed: (QueryTab) -> Bool
    ) {
        let addressed = tabs.filter { tab in
            tab.tabType == .table && tab.id != excludingTabId && isAddressed(tab)
        }
        staleTabIds = addressed.map(\.id)

        guard let selectedTab, let tab = addressed.first(where: { $0.id == selectedTab.id }) else {
            selectedTabAction = .noReload
            return
        }
        selectedTabAction = Self.action(
            for: tab,
            state: selectedTab,
            loadMisses: Self.landingLoadMisses(change, load: selectedTab.load)
        )
    }

    /// What the selected tab does about a change it already owes, once whatever put the reload off
    /// has gone. Asked on every such moment, a tab switch or a save included, so the tab's own load
    /// stands in the way like an edit does: one that claimed the tab after the change read what it
    /// wrote. Only a load that claimed the tab before the change is started again.
    static func resumedAction(
        for tab: QueryTab,
        state: SelectedTabState,
        owing change: TableFreshness.Change
    ) -> SelectedTabAction {
        action(for: tab, state: state, loadMisses: resumedLoadMisses(change, load: state.load))
    }

    private static func action(for tab: QueryTab, state: SelectedTabState, loadMisses: Bool) -> SelectedTabAction {
        guard !state.holdsEdits, loadMisses else { return .noReload }
        return tab.display.resultsViewMode == .structure ? .reloadBehindStructure : .reloadNow
    }

    /// A load running as the change lands chose its metadata before the mark existed.
    private static func landingLoadMisses(_ change: TableFreshness.Change, load: SelectedTabLoad) -> Bool {
        switch load {
        case .idle:
            return true
        case .scheduled, .extending:
            return false
        case .running(let startedAt):
            return !TableFreshness.inFlightRead(startedAt: startedAt, covers: change)
        }
    }

    /// Once the change is marked, a load claimed after it was either started with the mark in place
    /// or left to run when the change landed, and in that case the mark outlives what it misses.
    private static func resumedLoadMisses(_ change: TableFreshness.Change, load: SelectedTabLoad) -> Bool {
        switch load {
        case .idle:
            return true
        case .scheduled, .extending:
            return false
        case .running(let startedAt):
            return startedAt < change.at
        }
    }
}
