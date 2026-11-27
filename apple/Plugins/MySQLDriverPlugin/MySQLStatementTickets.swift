//
//  MySQLStatementTickets.swift
//  MySQLDriverPlugin
//

import Foundation

// A cancellation generation opens only on the connection's queue, so a user statement is numbered as the driver takes
// it and a Stop holds back every one numbered so far. One lock covers both, so a Stop holds a statement back or finds it open.
final class MySQLStatementTickets: @unchecked Sendable {
    struct Ticket: Sendable {
        fileprivate let number: UInt64
    }

    private let lock = NSLock()
    private var issued: UInt64 = 0
    private var stoppedThrough: UInt64 = 0

    func issue() -> Ticket {
        lock.withLock {
            issued += 1
            return Ticket(number: issued)
        }
    }

    func stop<T>(cancellingRunning cancel: () -> T) -> T {
        lock.withLock {
            stoppedThrough = issued
            return cancel()
        }
    }

    // A statement without a ticket is the driver's own and is never held back.
    func admit<T>(_ ticket: Ticket?, registering register: () -> T) throws -> T {
        try lock.withLock {
            if let ticket, ticket.number <= stoppedThrough { throw CancellationError() }
            return register()
        }
    }
}
