//
//  SessionDriverGate.swift
//  TablePro
//

import Foundation

/// Serialises access to a connection's single shared driver.
///
/// The driver carries one mutable position (its current database and schema), so an
/// operation has to move it before it runs. Without ordering, two windows interleave
/// their moves and each runs against the other's database.
///
/// The body runs inline in the caller's own task rather than in a detached one, so
/// cancellation still reaches the work.
///
/// A turn is owned by the ticket that took it, not by the connection. A drain ends the turn of a
/// holder that may still be stuck in a driver call, and when that holder finally returns, its
/// release must not free or hand off a turn a later session has taken since.
@MainActor
final class SessionDriverGate {
    private struct Waiter {
        let ticket: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var owners: [UUID: UUID] = [:]
    private var waiters: [UUID: [Waiter]] = [:]

    func withExclusiveAccess<T>(
        _ connectionId: UUID,
        _ body: () async throws -> T
    ) async throws -> T {
        let ticket = try await acquire(connectionId)
        defer { release(connectionId, ticket: ticket) }
        return try await body()
    }

    #if DEBUG
    /// How many callers are queued behind the holder, so a test can wait for one to reach the
    /// gate instead of guessing how many scheduler turns that takes.
    internal func waiterCount(for connectionId: UUID) -> Int {
        waiters[connectionId]?.count ?? 0
    }
    #endif

    /// Releases a connection that is going away, failing everyone still queued for it.
    func drain(connectionId: UUID) {
        owners.removeValue(forKey: connectionId)
        let pending = waiters.removeValue(forKey: connectionId) ?? []
        for waiter in pending {
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    private func acquire(_ connectionId: UUID) async throws -> UUID {
        let ticket = UUID()
        guard owners[connectionId] != nil else {
            owners[connectionId] = ticket
            return ticket
        }
        try await withTaskCancellationHandler(
            operation: { try await enqueue(ticket: ticket, connectionId: connectionId) },
            onCancel: { [weak self] in
                Task { @MainActor in
                    self?.failWaiter(ticket: ticket, connectionId: connectionId)
                }
            }
        )
        /// A hand-off resumes this caller before it runs, so a drain can land in between, and the
        /// turn it was handed ended with that drain.
        guard owners[connectionId] == ticket else {
            throw CancellationError()
        }
        return ticket
    }

    private func enqueue(ticket: UUID, connectionId: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard !Task.isCancelled else {
                continuation.resume(throwing: CancellationError())
                return
            }
            waiters[connectionId, default: []].append(
                Waiter(ticket: ticket, continuation: continuation)
            )
        }
    }

    /// Removes the ticket before resuming it, so a cancellation racing a hand-off
    /// can only ever find one of them.
    private func failWaiter(ticket: UUID, connectionId: UUID) {
        guard var pending = waiters[connectionId],
              let index = pending.firstIndex(where: { $0.ticket == ticket })
        else {
            return
        }
        let waiter = pending.remove(at: index)
        waiters[connectionId] = pending.isEmpty ? nil : pending
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release(_ connectionId: UUID, ticket: UUID) {
        guard owners[connectionId] == ticket else { return }
        guard var pending = waiters[connectionId], !pending.isEmpty else {
            owners.removeValue(forKey: connectionId)
            waiters.removeValue(forKey: connectionId)
            return
        }
        let next = pending.removeFirst()
        waiters[connectionId] = pending.isEmpty ? nil : pending
        owners[connectionId] = next.ticket
        next.continuation.resume()
    }
}
