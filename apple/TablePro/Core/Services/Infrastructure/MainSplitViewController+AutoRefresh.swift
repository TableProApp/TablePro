//
//  MainSplitViewController+AutoRefresh.swift
//  TablePro
//

import AppKit

extension MainSplitViewController {
    @objc func setTableAutoRefreshInterval(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? Int,
              let interval = TableAutoRefreshInterval(rawValue: raw) else { return }
        commandActions?.setTableAutoRefreshInterval(interval)
    }

    // Nil off a table tab, so the submenu's checkmark never names another tab's interval.
    var tableAutoRefreshInterval: TableAutoRefreshInterval? {
        guard contentMode == .browse, isConnected else { return nil }
        return commandActions?.tableAutoRefreshInterval
    }

    var canSetTableAutoRefresh: Bool {
        tableAutoRefreshInterval != nil && !(isViewLoaded && view.window?.attachedSheet != nil)
    }
}
