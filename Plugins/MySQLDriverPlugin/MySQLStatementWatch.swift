//
//  MySQLStatementWatch.swift
//  MySQLDriverPlugin
//
//  Which statement the client-side deadline is allowed to interrupt, and whether it did.
//

import Foundation

/// `KILL QUERY` sets a flag on the server's thread that the *next* statement to test it consumes,
/// so a kill that lands after the statement it was meant for has already finished interrupts an
/// innocent one instead. Measured on MySQL 5.5.62, 5.6.51 and MariaDB 5.5.64: after an idle
/// `KILL QUERY`, the following `SELECT COUNT(*) FROM information_schema.COLLATIONS a, b` and
/// `INSERT ... SELECT` both failed with `ERROR 1317` and the row was not inserted.
///
/// Two things close that window. The interrupt runs under this lock and only while the token it
/// names is still the running statement, and `end` takes the same lock, so the statement cannot
/// finish, and therefore the next one on the serial queue cannot start, while a kill is in flight.
/// And `end` reports whether a kill was sent, so a caller whose statement did not end in an
/// interruption knows to consume the flag itself before releasing the queue.
internal final class MySQLStatementWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var lastToken: UInt64 = 0
    private var runningToken: UInt64?
    private var interruptedToken: UInt64?

    internal init() {}

    internal func begin() -> UInt64 {
        lock.withLock {
            lastToken += 1
            runningToken = lastToken
            return lastToken
        }
    }

    /// Whether a kill was sent for this statement. Blocks while an interrupt for it is in flight.
    internal func end(_ token: UInt64) -> Bool {
        lock.withLock {
            if runningToken == token { runningToken = nil }
            guard interruptedToken == token else { return false }
            interruptedToken = nil
            return true
        }
    }

    internal func isRunning(_ token: UInt64) -> Bool {
        lock.withLock { runningToken == token }
    }

    /// Runs `interrupt` only while `token` is still the running statement, and records that a kill
    /// was sent only when it reports one went out.
    internal func expire(_ token: UInt64, interrupt: () -> Bool) {
        lock.withLock {
            guard runningToken == token, interrupt() else { return }
            interruptedToken = token
        }
    }
}
