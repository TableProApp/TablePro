//
//  MainContentCoordinator+SafeModePromptRetry.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    // The prompt is one per window, so a first load that meets another run's prompt waits for it to close.
    func turnAwayTableLoad(tabId: UUID, trigger: TableLoadTrigger) {
        traceNavigationAbandoned(tabId: tabId, outcome: .safeModePromptAlreadyOpen)
        tableLoadTurnedAwayByPrompt = ParkedTableLoad(tabId: tabId, trigger: trigger)
        declineTableLoad(for: tabId)
    }

    func safeModePromptDidChange(wasShowing: Bool) {
        guard wasShowing, !isShowingSafeModePrompt, tableLoadTurnedAwayByPrompt != nil else { return }
        // Once the run that lowered it has started, so a load it starts itself is not asked for twice.
        Task { @MainActor [weak self] in self?.retryTableLoadTurnedAwayByPrompt() }
    }

    private func retryTableLoadTurnedAwayByPrompt() {
        guard !isShowingSafeModePrompt, !isTearingDown, let turnedAway = tableLoadTurnedAwayByPrompt else { return }
        tableLoadTurnedAwayByPrompt = nil
        guard turnedAway.tabId == tabManager.selectedTabId else { return }
        lazyLoadCurrentTabIfNeeded(trigger: turnedAway.trigger)
    }
}
