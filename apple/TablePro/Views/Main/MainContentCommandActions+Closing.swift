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
            guard await saveSelectedTabWork() else { return }
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
}
