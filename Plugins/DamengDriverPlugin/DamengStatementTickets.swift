import Foundation

/// Decides which statement a dropped Swift task is allowed to interrupt.
///
/// `tp_dm_cancel` is connection-wide and stopping a DM8 statement closes the connection, so a
/// task cancellation aimed at a statement still queued behind another would destroy the one on
/// the wire instead. A ticket keeps each cancellation to its own statement: a queued one is
/// dropped before it reaches the socket, only the executing one is interrupted, and one that
/// already finished is ignored.
///
/// A user's Stop is a different thing and does not come through here. `cancelQuery()` is
/// connection-scoped by contract, and interrupting whatever is on the wire is what it means.
struct DamengStatementTickets {
    enum Cancellation: Equatable {
        /// The statement is on the wire. Interrupting it is the only way to stop it, and it
        /// costs the connection.
        case interruptConnection
        /// The statement never reached the socket, so it is dropped without touching the
        /// connection. Cancelling one used to only set the connection-wide flag, which the
        /// next statement cleared on its way in, so the abandoned work ran anyway.
        case dropQueued
        /// Already finished, or never issued.
        case ignore
    }

    private var nextTicket: UInt64 = 0
    private var live: Set<UInt64> = []
    private var executing: UInt64?
    private var cancelled: Set<UInt64> = []

    mutating func issue() -> UInt64 {
        nextTicket &+= 1
        live.insert(nextTicket)
        return nextTicket
    }

    /// Returns false when the statement must not reach the socket: the caller cancelled it, or
    /// the connection it was queued on has since been retired. Checking `live` matters because
    /// `reset` clears the cancellations too, and without it a rebuild would run work the caller
    /// had already abandoned.
    mutating func beginExecuting(_ ticket: UInt64) -> Bool {
        guard live.contains(ticket) else { return false }
        guard cancelled.remove(ticket) == nil else {
            live.remove(ticket)
            return false
        }
        executing = ticket
        return true
    }

    mutating func finishExecuting(_ ticket: UInt64) {
        live.remove(ticket)
        cancelled.remove(ticket)
        if executing == ticket { executing = nil }
    }

    mutating func cancel(_ ticket: UInt64) -> Cancellation {
        if executing == ticket { return .interruptConnection }
        guard live.contains(ticket), cancelled.insert(ticket).inserted else { return .ignore }
        return .dropQueued
    }

    /// Drops the bookkeeping for statements a closed connection will never run.
    mutating func reset() {
        live.removeAll()
        cancelled.removeAll()
        executing = nil
    }
}
