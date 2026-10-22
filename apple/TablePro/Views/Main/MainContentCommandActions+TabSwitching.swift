//
//  MainContentCommandActions+TabSwitching.swift
//  TablePro
//

import Foundation

extension MainContentCommandActions {
    func selectTab(number: Int) {
        guard let manager = coordinator?.tabManager else { return }
        switchTab(in: manager, to: manager.tabId(at: number - 1), trigger: .tabNumber)
    }

    func selectTab(offsetBy offset: Int) {
        guard let manager = coordinator?.tabManager else { return }
        switchTab(in: manager, to: manager.tabId(offsetBy: offset), trigger: .adjacentTab)
    }

    private func switchTab(in manager: QueryTabManager, to id: UUID?, trigger: TabSwitchTrigger) {
        guard let id, id != manager.selectedTabId else { return }
        TabSwitchTracer.shared.requestSwitch(trigger, to: id)
        manager.selectedTabId = id
    }
}
