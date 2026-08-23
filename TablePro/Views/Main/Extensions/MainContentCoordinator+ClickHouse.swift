//
//  MainContentCoordinator+ClickHouse.swift
//  TablePro
//
//  ClickHouse-specific coordinator methods: progress tracking.
//

import Foundation

extension MainContentCoordinator {
    func installClickHouseProgressHandler() {
        // Progress polling is handled internally by the ClickHouse plugin.
        // This is a no-op stub retained for call-site compatibility.
    }

    func clearClickHouseProgress() {
        if let live = toolbarState.clickHouseProgress {
            toolbarState.lastClickHouseProgress = live
        }
        toolbarState.clickHouseProgress = nil
    }
}
