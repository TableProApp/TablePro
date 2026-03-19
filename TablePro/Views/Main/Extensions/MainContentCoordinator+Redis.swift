//
//  MainContentCoordinator+Redis.swift
//  TablePro
//
//  Redis-specific query helpers for MainContentCoordinator.
//

import Foundation

extension MainContentCoordinator {
    /// Cancel any in-flight Redis database switch task to prevent race conditions
    /// from rapid sidebar clicks.
    func cancelRedisDatabaseSwitchTask() {
        redisDatabaseSwitchTask?.cancel()
        redisDatabaseSwitchTask = nil
    }
}
