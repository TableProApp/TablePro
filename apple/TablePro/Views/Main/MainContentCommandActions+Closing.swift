//
//  MainContentCommandActions+Closing.swift
//  TablePro
//

import AppKit

extension MainContentCommandActions {
    // Asked only when nothing is unsaved; otherwise the save question names the work. Stopping waits for the close.
    internal func confirmsStoppingWork(_ work: [RunningWork]) async -> Bool {
        guard let prompt = RunningWorkPrompt.make(action: .close, work: work) else { return true }
        return await confirmStoppingWork(prompt, closeAnchorWindow)
    }

    internal func stop(_ work: [RunningWork]) {
        for item in work { item.cancel() }
    }

    var workInWindow: [RunningWork] {
        let coordinators: [MainContentCoordinator]
        if let host = window?.contentViewController as? MainSplitViewController {
            coordinators = host.workspaces.workspaces.compactMap { $0.sessionState?.coordinator }
        } else {
            coordinators = [coordinator].compactMap { $0 }
        }
        return runningWork(.window(
            ids: Set(coordinators.compactMap(\.windowId)),
            connectionIds: Set(coordinators.map(\.connectionId))
        ))
    }

    // Asks before closing unsaved work (HIG); like NSDocument, the tab stays open when the save leaves work unsaved.
    func closeTabAwaiting(id: UUID) async {
        guard let coordinator else { return }
        // An open cell editor or the editor's pending text is unsaved work too, so it lands before the tab is read.
        if coordinator.tabManager.selectedTabId == id {
            coordinator.commitActiveGridEdit()
        }
        guard let tab = coordinator.tabManager.tabs.first(where: { $0.id == id }) else { return }
        let work = runningWork(.tabs([id]))
        guard !work.isEmpty || coordinator.hasUnsavedWork(in: tab) else {
            coordinator.closeTabsByUser(ids: [id])
            return
        }
        guard coordinator.tabClosesInFlight.insert(id).inserted else { return }
        defer { coordinator.tabClosesInFlight.remove(id) }

        let previousSelection = coordinator.tabManager.selectedTabId
        revealTab(id)

        guard coordinator.hasUnsavedWork(in: tab) else {
            guard await confirmsStoppingWork(work) else {
                if coordinator.tabManager.selectedTabId == id { restoreSelection(previousSelection) }
                return
            }
            stop(work)
            closeRevealedTab(id, returningTo: previousSelection)
            return
        }

        switch await confirmSaveChanges(
            RunningWorkPrompt.saveMessage(
                String(localized: "Your changes will be lost if you don't save them."),
                action: .close,
                alsoStopping: work
            ),
            closeAnchorWindow
        ) {
        case .save:
            // A tab picked during the prompt refuses the save, and with it the close: its editors are not this tab's.
            guard await saveWork(onTab: id) else { return }
            stop(work)
            closeRevealedTab(id, returningTo: previousSelection)
        case .dontSave:
            stop(work)
            closeRevealedTab(id, returningTo: previousSelection)
        case .cancel:
            guard coordinator.tabManager.selectedTabId == id else { return }
            restoreSelection(previousSelection)
        }
    }

    // A save can wait on the server; a tab the user picked meanwhile is a newer choice than the one this close set aside.
    func closeRevealedTab(_ id: UUID, returningTo previousSelection: UUID?) {
        guard let coordinator else { return }
        let stillShowsClosingTab = coordinator.tabManager.selectedTabId == id
        coordinator.closeTabsByUser(ids: [id])
        guard stillShowsClosingTab else { return }
        restoreSelection(previousSelection)
    }

    // Save and discard read the selected tab, and the user should see the work the alert asks about.
    func revealTab(_ id: UUID) {
        guard let coordinator, coordinator.tabManager.selectedTabId != id else { return }
        coordinator.tabManager.selectedTabId = id
    }

    // The selection moved only for the alert; a closed front tab lands on its neighbour since the tab to restore is gone.
    func restoreSelection(_ id: UUID?) {
        guard let coordinator,
              let id,
              coordinator.tabManager.selectedTabId != id,
              coordinator.tabManager.tabs.contains(where: { $0.id == id }) else { return }
        coordinator.tabManager.selectedTabId = id
    }

    // False while work is still staged after the attempt (review sheet, refused or cancelled DDL, file conflict, Save As cancel).
    func saveSelectedTabWork() async -> Bool {
        await saveWork(onTab: coordinator?.tabManager.selectedTabId)
    }

    // False once another tab is in front or the tab is gone: the mounted editors, grid and inspector it saves are the front tab's.
    func saveWork(onTab tabId: UUID?) async -> Bool {
        guard let coordinator = coordinator else { return true }
        let manager = coordinator.tabManager
        let stillOnTab = { manager.selectedTabId == tabId && (tabId == nil || manager.selectedTabIndex != nil) }
        guard stillOnTab() else { return false }

        if isUsersRolesTab, coordinator.usersRolesActions?.hasChanges() == true {
            coordinator.usersRolesActions?.reviewAndApply()
            return false
        }

        // Keyed on the session, not resultsViewMode, which let a Data-view or background tab close over its staged ALTERs.
        if let tabId,
           let session = coordinator.structureSessions[tabId],
           session.changeManager.hasChanges {
            guard await session.applyStagedChanges(coordinator: coordinator).allowsClose, stillOnTab() else {
                return false
            }
        }
        guard await applyDiagramEdits(ofTab: tabId, in: coordinator), stillOnTab() else { return false }
        guard await applyTypeChanges(ofTab: tabId), stillOnTab() else { return false }

        // Data grid changes or pending table operations take priority
        if hasDataWork {
            return await withCheckedContinuation { continuation in
                coordinator.saveCompletionContinuation = continuation
                saveChanges()
                // Still there when the command went somewhere other than the grid save, which reports nothing back.
                coordinator.takeSaveCompletion()?.resume(returning: false)
            }
        }

        if trailingPaneState.inspector.editState.hasEdits {
            return await saveInspectorEditsAwaiting()
        }

        // File save (query editor with source file)
        if coordinator.tabManager.selectedTab?.content.isFileDirty == true {
            return await saveSelectedFileAwaiting()
        }

        return true
    }
}
