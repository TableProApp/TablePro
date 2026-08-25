import Foundation

/// The single answer to "would closing or quitting destroy something the user cannot get back".
/// The close path (one tab) and the quit path (every tab of every connection) previously each
/// carried their own partial version of this and had drifted apart.
extension MainContentCoordinator {
    var hasPendingDestructiveTableOps: Bool {
        guard let session = DatabaseManager.shared.session(for: connectionId) else { return false }
        return !session.pendingTruncates.isEmpty || !session.pendingDeletes.isEmpty
    }

    var hasSidebarEdits: Bool {
        rightPanelState?.editState.hasEdits ?? false
    }

    /// Only the selected tab's editors are mounted, so only the selected tab has live state on the
    /// coordinator to read.
    func isSelectedTab(_ tab: QueryTab) -> Bool {
        tabManager.selectedTabId == tab.id
    }

    /// Work in one tab that only saving can recover.
    ///
    /// Where that work lives depends on whether the tab is selected, because a tab's editors are
    /// mounted only while it is. The selected tab's live edits sit on the coordinator, in
    /// `changeManager` and `toolbarState`; a background tab carries whatever was snapshotted into
    /// `pendingChanges` the last time it was switched away from. Reading the snapshot for the
    /// selected tab answers "no" for the gesture users make most, editing a cell and closing the
    /// tab they are looking at, because nothing has switched away to write the snapshot yet.
    ///
    /// Connection-scoped work is deliberately absent. A staged TRUNCATE or an unsaved sidebar edit
    /// belongs to the connection rather than to any one tab, so letting it gate a tab's close would
    /// pose a question neither Save nor Don't Save could answer for the tab being closed.
    ///
    /// A scratch query tab is absent too, and that one is a decision rather than an omission: its
    /// text is persisted with the tab and filed in `RecentlyClosedTabStore` on close, so it comes
    /// back. Grid edits do not. `TabChangeSnapshot` is not `Codable` and `PersistedTab` carries no
    /// change fields, so closing a table tab is the one gesture that destroys them for good.
    func hasUnsavedWork(in tab: QueryTab?) -> Bool {
        guard let tab else { return false }
        return savability(of: tab) != .nothingAtRisk
    }

    /// What a save can actually do for one tab, which is not the same question as whether it holds
    /// work. A batch close asks both: it saves what it can reach and leaves the rest open, so the
    /// two answers have to come from one switch. Reading the categories apart, in a second
    /// classifier beside this one, is how the alert and the save came to disagree about what Save
    /// covers.
    enum TabWorkSavability: Equatable {
        case nothingAtRisk
        /// Reachable without the tab on screen: its file, and the ALTERs staged in its own session.
        case saveable
        /// Only the tab's own editors can save it: grid edits, staged principals, a table draft.
        case mountedOnly
    }

    /// The unreachable kinds are asked about first. A tab can hold more than one: a query opened
    /// from a file, edited, with unsaved cell edits in its result. Answering `.saveable` for the file
    /// would let a close write the file and destroy the grid edits beside it, which is the loss this
    /// category exists to prevent.
    func savability(of tab: QueryTab) -> TabWorkSavability {
        guard isSelectedTab(tab) else {
            switch tab.tabType {
            case .usersRoles:
                guard !tabsWithStagedPrincipals.contains(tab.id) else { return .mountedOnly }
            case .createTable:
                guard !hasTableDraftWork(in: tab) else { return .mountedOnly }
            default:
                guard !tab.pendingChanges.hasChanges else { return .mountedOnly }
                if hasStagedStructureEdits(in: tab) { return .saveable }
            }
            return fileSavability(of: tab)
        }
        return liveUnsavedWork(in: tab) ? .saveable : fileSavability(of: tab)
    }

    private func fileSavability(of tab: QueryTab) -> TabWorkSavability {
        tab.content.isFileDirty ? .saveable : .nothingAtRisk
    }

    /// The selected tab's editors are mounted, so everything they hold is reachable and saving the
    /// selected tab covers all of it. A deselected tab left its editors behind, which is why
    /// `savability` answers for it from what they wrote down before they went: users and roles keeps
    /// its own record because its view model outlives the view while `usersRolesActions` does not,
    /// so the staged principals survive a deselect even though nothing on the coordinator can still
    /// reach them to apply.
    private func liveUnsavedWork(in tab: QueryTab) -> Bool {
        switch tab.tabType {
        case .usersRoles:
            return usersRolesActions?.hasChanges() ?? tabsWithStagedPrincipals.contains(tab.id)
        case .createTable:
            return toolbarState.hasCreateTablePending || hasTableDraftWork(in: tab)
        default:
            return changeManager.hasChanges
                || toolbarState.hasStructureChanges
                || hasStagedStructureEdits(in: tab)
        }
    }

    /// Staged ALTERs read from the tab's own session rather than from `toolbarState`, which only
    /// ever describes the tab on screen. A background tab keeps its session, so this is the only
    /// answer that holds once the user has switched away from it.
    func hasStagedStructureEdits(in tab: QueryTab) -> Bool {
        structureSessions[tab.id]?.changeManager.hasChanges ?? false
    }

    func hasTableDraftWork(in tab: QueryTab) -> Bool {
        createTableDrafts[tab.id]?.holdsWork ?? false
    }

    /// The dot on the tab and in the window's close button. Deliberately broader than
    /// `hasUnsavedWork(in:)`: a scratch query tab shows the dot because its text is unsaved, yet
    /// closing it asks nothing because the text comes back. It is never narrower, so anything that
    /// would raise the save prompt is marked before the user reaches for the close button.
    func showsUnsavedIndicator(for tab: QueryTab) -> Bool {
        tab.showsUnsavedIndicator || hasUnsavedWork(in: tab)
    }

    func hasAnyUnsavedWork() -> Bool {
        changeManager.hasChanges
            || hasPendingDestructiveTableOps
            || hasSidebarEdits
            || toolbarState.hasStructureChanges
            || toolbarState.hasCreateTablePending
            || tabManager.tabs.contains { hasUnsavedWork(in: $0) }
    }

    /// Tabs resolved against live view state (cursor offset, sort column names) so a reopened tab
    /// comes back where the user left it.
    func tabsForRecoveryCapture() -> [QueryTab] {
        tabManager.tabs.map { enrichedForPersistence($0) }
    }
}
