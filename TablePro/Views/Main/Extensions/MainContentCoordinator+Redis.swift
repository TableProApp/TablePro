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

    /// The click has already retargeted the tab, so a server that refuses the database (a single
    /// database service answering `ERR DB index is out of range`, or an ACL without `select`)
    /// has to say so there, or the tab sits empty under a database it never reached. A selection
    /// that was superseded or lost its connection is not the server's answer, and the connection's
    /// own state reports a disconnect.
    func reportRedisSelectionFailure(_ error: Error, onTab tabId: UUID) {
        if DatabaseCancellationDiagnosis.isCancellation(error) {
            declineTableLoad(for: tabId)
            return
        }
        if case DatabaseError.notConnected = error {
            declineTableLoad(for: tabId)
            return
        }
        let diagnosis = DatabaseWriteRejectionDiagnosis.formatted(error)
        queryExecutionCoordinator.presentTabFailure(diagnosis, announcing: diagnosis, onTab: tabId)
    }
}
