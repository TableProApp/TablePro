//
//  MainContentCoordinator+DraftSave.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    static let periodicSaveInterval: Duration = .seconds(30)
    static let draftSaveDebounce: Duration = .seconds(1)

    // Typing changes no tab identity, so without this a scratch query lives only in memory until the 30s timer or quit flush.
    // Any window may save: `saveAggregated` writes every window's tabs for the connection.
    func scheduleDraftSave(editedTab tabId: UUID? = nil) {
        guard !Self.isAppTerminating, !isTearingDown else { return }
        if let tabId { draftSaveTabIds.insert(tabId) }
        draftSaveTask?.cancel()
        let clock = draftSaveClock
        draftSaveTask = Task { [weak self] in
            try? await clock.sleep(for: Self.draftSaveDebounce)
            guard let self, !Task.isCancelled, !Self.isAppTerminating, !self.isTearingDown else { return }
            self.recordIdleVersions()
            self.persistence.saveAggregated()
        }
    }

    func startPeriodicSave() {
        guard periodicSaveTask == nil else { return }
        periodicSaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.periodicSaveInterval)
                guard let self, !Task.isCancelled, !Self.isAppTerminating, !self.isTearingDown else { return }
                guard self.isFirstCoordinatorForConnection() else { continue }
                self.persistence.saveAggregated()
            }
        }
    }

    static func aggregatedSelectedTabId(for connectionId: UUID) -> UUID? {
        activeCoordinators.values
            .first { $0.connectionId == connectionId && $0.tabManager.selectedTabId != nil }?
            .tabManager.selectedTabId
    }

    private func isFirstCoordinatorForConnection() -> Bool {
        Self.activeCoordinators.values
            .first { $0.connectionId == self.connectionId } === self
    }

    private func recordIdleVersions() {
        let tabIds = draftSaveTabIds
        draftSaveTabIds.removeAll()
        for tabId in tabIds {
            tabVersions.record(tabManager.tabs.first { $0.id == tabId }, connectionId: connectionId, reason: .idle)
        }
    }
}
