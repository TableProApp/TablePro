//
//  SessionDriverGate.swift
//  TablePro
//

import Foundation

/// Serialises access to a connection's shared session drivers.
///
/// The driver carries one mutable position (its current database and schema), so an
/// operation has to move it before it runs. Without ordering, two windows interleave
/// their moves and each runs against the other's database.
///
/// A connection that keeps one driver per database (see `SessionLanes`) takes one turn per
/// database: each of those drivers sits on its own database for good, so work on two databases
/// never has to wait for the other, while two operations on one database still take turns.
///
/// The body runs inline in the caller's own task rather than in a detached one, so
/// cancellation still reaches the work.
///
/// A turn is owned by the ticket that took it, not by the connection. A drain ends the turn of a
/// holder that may still be stuck in a driver call, and when that holder finally returns, its
/// release must not free or hand off a turn a later session has taken since.
@MainActor
final class SessionDriverGate {
    /// One turn per connection, or per database of a connection that keeps a driver per database.
    struct Key: Hashable {
        let connectionId: UUID
        let database: String?
    }

    private struct Waiter {
        let ticket: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var owners: [Key: UUID] = [:]
    private var waiters: [Key: [Waiter]] = [:]

    func withExclusiveAccess<T>(
        _ connectionId: UUID,
        _ body: () async throws -> T
    ) async throws -> T {
        try await withExclusiveAccess(Key(connectionId: connectionId, database: nil), body)
    }

    func withExclusiveAccess<T>(
        _ key: Key,
        _ body: () async throws -> T
    ) async throws -> T {
        let ticket = try await acquire(key)
        defer { release(key, ticket: ticket) }
        return try await body()
    }

    /// Whether a turn is running on `key`, which for a connection's own driver is proof that it is
    /// answering without asking it again.
    func isHeld(_ key: Key) -> Bool {
        owners[key] != nil
    }

    #if DEBUG
    /// How many callers are queued behind the holder, so a test can wait for one to reach the
    /// gate instead of guessing how many scheduler turns that takes.
    internal func waiterCount(for connectionId: UUID) -> Int {
        waiters.filter { $0.key.connectionId == connectionId }.values.reduce(0) { $0 + $1.count }
    }
    #endif

    /// Releases a connection that is going away, failing everyone still queued for any of its turns.
    func drain(connectionId: UUID) {
        let keys = Set(owners.keys).union(waiters.keys).filter { $0.connectionId == connectionId }
        for key in keys {
            owners.removeValue(forKey: key)
            let pending = waiters.removeValue(forKey: key) ?? []
            for waiter in pending {
                waiter.continuation.resume(throwing: CancellationError())
            }
        }
    }

    private func acquire(_ key: Key) async throws -> UUID {
        let ticket = UUID()
        guard owners[key] != nil else {
            owners[key] = ticket
            return ticket
        }
        try await withTaskCancellationHandler(
            operation: { try await enqueue(ticket: ticket, key: key) },
            onCancel: { [weak self] in
                Task { @MainActor in
                    self?.failWaiter(ticket: ticket, key: key)
                }
            }
        )
        /// A hand-off resumes this caller before it runs, so a drain can land in between, and the
        /// turn it was handed ended with that drain.
        guard owners[key] == ticket else {
            throw CancellationError()
        }
        return ticket
    }

    private func enqueue(ticket: UUID, key: Key) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard !Task.isCancelled else {
                continuation.resume(throwing: CancellationError())
                return
            }
            waiters[key, default: []].append(
                Waiter(ticket: ticket, continuation: continuation)
            )
        }
    }

    /// Removes the ticket before resuming it, so a cancellation racing a hand-off
    /// can only ever find one of them.
    private func failWaiter(ticket: UUID, key: Key) {
        guard var pending = waiters[key],
              let index = pending.firstIndex(where: { $0.ticket == ticket })
        else {
            return
        }
        let waiter = pending.remove(at: index)
        waiters[key] = pending.isEmpty ? nil : pending
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release(_ key: Key, ticket: UUID) {
        guard owners[key] == ticket else { return }
        guard var pending = waiters[key], !pending.isEmpty else {
            owners.removeValue(forKey: key)
            waiters.removeValue(forKey: key)
            return
        }
        let next = pending.removeFirst()
        waiters[key] = pending.isEmpty ? nil : pending
        owners[key] = next.ticket
        next.continuation.resume()
    }
}
