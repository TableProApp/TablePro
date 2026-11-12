//
//  MainContentCoordinator+ManualCommit.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    // A table tab's read and an auto-load are the app's own SELECTs, so they never hold anything.
    func manualCommitRun(skipped: Bool) -> ManualCommitRun {
        ManualCommitRun(
            commitMode: skipped ? .automatic : services.databaseManager.commitMode(for: connectionId),
            databaseType: connection.type,
            grammar: lexicalGrammar,
            connectionId: connectionId
        )
    }
}
