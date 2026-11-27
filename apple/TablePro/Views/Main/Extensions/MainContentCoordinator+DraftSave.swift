//
//  MainContentCoordinator+DraftSave.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    static let draftSaveDebounce: Duration = .seconds(1)

    // Every write to what a tab save reads lands here through `QueryTabManager.notePersistedStateChange`, so nothing
    // wakes while nothing changes. Any window may save: `saveAggregated` writes every window's tabs for the connection.
    func scheduleDraftSave(editedTab tabId: UUID? = nil) {
        guard !Self.isAppTerminating, !isTearingDown else { return }
        if let tabId { draftSaveTabIds.insert(tabId) }
        draftSaveTask?.cancel()
        let clock = draftSaveClock
        draftSaveTask = Task { [weak self] in
            try? await clock.sleep(for: Self.draftSaveDebounce)
            guard let self, !Task.isCancelled, !Self.isAppTerminating, !self.isTearingDown else { return }
            self.recordIdleVersions()
            self.persistence.saveAggregatedIfChanged()
        }
    }

    static func aggregatedSelectedTabId(for connectionId: UUID) -> UUID? {
        activeCoordinators.values
            .first { $0.connectionId == connectionId && $0.tabManager.selectedTabId != nil }?
            .tabManager.selectedTabId
    }

    private func recordIdleVersions() {
        let tabIds = draftSaveTabIds
        draftSaveTabIds.removeAll()
        for tabId in tabIds {
            tabVersions.record(tabManager.tabs.first { $0.id == tabId }, connectionId: connectionId, reason: .idle)
        }
    }
}
