//
//  CancellationFlag.swift
//  TablePro
//

import Foundation
import os

/// A cancellation signal a blocking loop can read.
///
/// `Task.isCancelled` is only visible to the task itself, and a transfer runs its libssh2 calls on a
/// serial queue where that task does not exist. Flipping a flag from `withTaskCancellationHandler`
/// gives the loop something it can check between chunks, which is the same shape the drivers use for
/// a connect that cannot be interrupted mid-call.
///
/// The SFTP session interrupts its transport to wake a read already inside libssh2; this flag makes
/// that wakeup report cancellation and stops the loop before it starts another chunk.
final class CancellationFlag: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    var isCancelled: Bool { state.withLock { $0 } }

    func cancel() {
        state.withLock { $0 = true }
    }
}
