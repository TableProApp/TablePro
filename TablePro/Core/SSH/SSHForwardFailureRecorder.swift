//
//  SSHForwardFailureRecorder.swift
//  TablePro
//

import Foundation
import os

/// Holds why a forwarding channel last failed so the connect path can report that instead of
/// the database driver's own error. A driver dialing the local port only ever sees a socket
/// that was accepted and then stayed silent, so its error names a read timeout and never the
/// cause. Only failures are recorded: a later successful open belongs to a different client
/// and must not clear a reason the connect path has not read yet.
internal final class SSHForwardFailureRecorder: Sendable {
    private let pending = OSAllocatedUnfairLock<SSHTunnelError?>(initialState: nil)

    func record(_ outcome: ChannelOpenOutcome, destination: SSHForwardDestination, deadlineSeconds: Int) {
        guard let error = outcome.tunnelError(destination: destination, deadlineSeconds: deadlineSeconds) else {
            return
        }
        pending.withLock { $0 = error }
    }

    /// Reads and clears the recorded reason, so a stale failure cannot be attributed to a
    /// later connect attempt that failed for an unrelated reason.
    func consume() -> SSHTunnelError? {
        pending.withLock { failure in
            defer { failure = nil }
            return failure
        }
    }
}
