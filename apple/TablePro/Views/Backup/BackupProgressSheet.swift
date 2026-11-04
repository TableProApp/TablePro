//
//  BackupProgressSheet.swift
//  TablePro
//

import SwiftUI

extension NativeDumpBatchState {
    // The total is the database's size, which a compressed dump never reaches, so it is an estimate.
    var transferProgress: TransferProgress {
        TransferProgress(
            job: .backup(databaseCount: total),
            item: currentLabel.isEmpty ? currentDatabase : currentLabel,
            step: TransferProgress.Step(index: currentIndex, count: total),
            completed: bytesProcessed,
            total: totalBytes,
            unit: .bytes,
            isEstimate: true,
            isStopping: isCancelling
        )
    }
}

extension NativeDumpState {
    // A stopping run keeps the bytes it last reported.
    func restoreProgress(database: String, last: TransferProgress?) -> TransferProgress {
        switch self {
        case .running(_, _, let bytes, let total):
            return TransferProgress(job: .restore, item: database, completed: bytes, total: total, unit: .bytes)
        case .cancelling:
            var progress = last ?? TransferProgress(job: .restore, item: database, unit: .bytes)
            progress.isStopping = true
            return progress
        case .idle, .finished, .failed, .cancelled:
            return last ?? TransferProgress(job: .restore, item: database, unit: .bytes)
        }
    }
}
