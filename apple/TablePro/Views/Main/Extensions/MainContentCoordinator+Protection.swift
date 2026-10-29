import AppKit
import Foundation

// The one answer to "would closing or quitting destroy something the user cannot get back", for close and quit alike.
extension MainContentCoordinator {
    var hasPendingDestructiveTableOps: Bool {
        guard let session = DatabaseManager.shared.session(for: connectionId) else { return false }
        return !session.pendingTruncates.isEmpty || !session.pendingDeletes.isEmpty
    }

    var hasSidebarEdits: Bool {
        trailingPaneState?.inspector.editState.hasEdits ?? false
    }

    // Only the selected tab's editors are mounted, so only it has live state on the coordinator.
    func isSelectedTab(_ tab: QueryTab) -> Bool {
        tabManager.selectedTabId == tab.id
    }

    // Connection-scoped work (a staged TRUNCATE, a sidebar edit) is left out: no tab's Save or Don't Save answers it.
    // A scratch query's text is left out too: it is persisted and comes back from Reopen Closed Tab.
    func hasUnsavedWork(in tab: QueryTab?) -> Bool {
        guard let tab else { return false }
        return savability(of: tab) != .nothingAtRisk
    }

    // An unknown id answers true: refusing a move is recoverable, moving a tab this window cannot see is not.
    func hasUnsavedWork(forTab id: UUID) -> Bool {
        guard let tab = tabManager.tabs.first(where: { $0.id == id }) else { return true }
        return savability(of: tab) != .nothingAtRisk
    }

    // One switch answers both "holds work" and "can Save reach it", so a batch close's alert and save cannot disagree.
    enum TabWorkSavability: Equatable {
        case nothingAtRisk
        // Reachable without the tab on screen: its file, and the ALTERs staged in its own session.
        case saveable
        // Only the tab's own editors can save it: grid edits, staged principals, a table draft.
        case mountedOnly
    }

    // Unreachable kinds first: answering `.saveable` for a dirty file would let a close drop the grid edits beside it.
    func savability(of tab: QueryTab) -> TabWorkSavability {
        guard isSelectedTab(tab) else {
            switch tab.tabType {
            case .usersRoles:
                guard !tabsWithStagedPrincipals.contains(tab.id) else { return .mountedOnly }
            case .createTable:
                guard !hasTableDraftWork(in: tab) else { return .mountedOnly }
            default:
                guard !tab.pendingChanges.hasChanges else { return .mountedOnly }
                if hasStagedStructureEdits(in: tab) || hasStagedTypeChanges(in: tab) { return .saveable }
            }
            return fileSavability(of: tab)
        }
        return liveUnsavedWork(in: tab) ? .saveable : fileSavability(of: tab)
    }

    private func fileSavability(of tab: QueryTab) -> TabWorkSavability {
        tab.content.isFileDirty ? .saveable : .nothingAtRisk
    }

    // Users & Roles keeps its own record because its view model outlives `usersRolesActions`.
    private func liveUnsavedWork(in tab: QueryTab) -> Bool {
        switch tab.tabType {
        case .usersRoles:
            return usersRolesActions?.hasChanges() ?? tabsWithStagedPrincipals.contains(tab.id)
        case .createTable:
            return toolbarState.hasCreateTablePending || hasTableDraftWork(in: tab)
        default:
            return changeManager.hasChanges
                || hasStagedStructureEdits(in: tab)
                || hasStagedTypeChanges(in: tab)
        }
    }

    // Read from the tab's session, mounted or not, so it holds in Data view and in a background tab.
    func hasStagedStructureEdits(in tab: QueryTab) -> Bool {
        (structureSessions[tab.id].map { $0.changeManager.hasChanges || $0.editor.hasPendingFieldDraft } ?? false)
            || (erDiagramModels[tab.id]?.holdsUnsavedWork ?? false)
    }

    var selectedDiagramHasStagedEdits: Bool {
        guard let tab = tabManager.selectedTab, tab.tabType == .erDiagram else { return false }
        return erDiagramModels[tab.id]?.hasStagedEdits ?? false
    }

    func hasStagedTypeChanges(in tab: QueryTab) -> Bool {
        userTypeEditors[tab.id]?.hasChanges ?? false
    }

    func hasTableDraftWork(in tab: QueryTab) -> Bool {
        createTableDrafts[tab.id].map { $0.holdsWork || $0.editor.hasPendingFieldDraft } ?? false
    }

    // Never narrower than `hasUnsavedWork(in:)`; broader for a scratch tab, whose text is unsaved but comes back.
    func showsUnsavedIndicator(for tab: QueryTab) -> Bool {
        tab.showsUnsavedIndicator || hasUnsavedWork(in: tab)
    }

    // For changes that bypass the editor's text binding, which pushes the dot on every keystroke itself.
    func refreshUnsavedIndicator() {
        guard let tab = tabManager.selectedTab, let window = contentWindow else { return }
        let showsIndicator = showsUnsavedIndicator(for: tab)
        Task { @MainActor in
            window.isDocumentEdited = showsIndicator
        }
    }

    func hasAnyUnsavedWork() -> Bool {
        changeManager.hasChanges
            || hasPendingDestructiveTableOps
            || hasSidebarEdits
            || toolbarState.hasCreateTablePending
            || tabManager.tabs.contains { hasUnsavedWork(in: $0) }
    }

    // Resolved against live view state (cursor, sort column names) so a reopened tab comes back where it was left.
    func tabsForRecoveryCapture() -> [QueryTab] {
        tabManager.tabs.map { enrichedForPersistence($0) }
    }
}
