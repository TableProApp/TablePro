//
//  MainSplitViewController+QueryTabVersions.swift
//  TablePro
//

import AppKit

extension MainSplitViewController {
    @objc func revertToQueryTabVersion(_ sender: Any?) {
        guard let choice = (sender as? NSMenuItem)?.representedObject as? QueryTabRevertChoice else { return }
        commandActions?.coordinator?.revertQueryTab(choice.tabId, toVersion: choice.versionId)
    }

    @objc func browseQueryTabVersions(_ sender: Any?) {
        guard let tabId = selectedQueryTabId else { return }
        commandActions?.coordinator?.showVersionHistory(ofQueryTab: tabId)
    }

    var selectedQueryTabId: UUID? {
        guard let tab = commandActions?.coordinator?.tabManager.selectedTab, tab.tabType == .query else { return nil }
        return tab.id
    }
}
