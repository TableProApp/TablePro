//
//  SSHSessionRegistry.swift
//  TablePro
//

import Foundation

internal protocol SSHSharedTransport: AnyObject, Sendable {
    var isRunning: Bool { get }
    func close()
}

// Hands every connection on one route the same SSH session. Connections that start together (Reopen Last
// Session, recovery after wake) wait on the one sign-in already under way instead of each starting its own, and
// the session closes when the last connection gives its lease back. A waiter that is cancelled leaves without
// failing the others; when the last one leaves, the sign-in is cancelled.
internal actor SSHSessionRegistry<Key: Hashable & Sendable, Session: SSHSharedTransport> {
    struct Lease: Sendable {
        let session: Session
        let token: UUID
        // The session was already live when this lease took it, so it may have died unnoticed.
        let reused: Bool
    }

    private final class Connecting {
        let id = UUID()
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<Session, any Error>] = [:]
    }

    private enum Entry {
        case connecting(Connecting)
        case live(Session, holders: Set<UUID>)
    }

    private var entries: [Key: Entry] = [:]

    init() {}

    // A waiter leaves at its own deadline with `timedOut`, whatever deadline the sign-in it joined runs under.
    func acquire(
        _ key: Key,
        deadline: ContinuousClock.Instant? = nil,
        timedOut: @escaping @Sendable () -> any Error = { CancellationError() },
        make: @escaping @Sendable () async throws -> Session
    ) async throws -> Lease {
        let token = UUID()
        switch entries[key] {
        case .live(let session, var holders)?:
            if session.isRunning {
                holders.insert(token)
                entries[key] = .live(session, holders: holders)
                return Lease(session: session, token: token, reused: true)
            }
            entries[key] = nil
        case .connecting(let connecting)?:
            let session = try await wait(on: connecting, key: key, token: token, deadline: deadline, timedOut: timedOut)
            return Lease(session: session, token: token, reused: false)
        case nil:
            break
        }

        let connecting = Connecting()
        let connectingId = connecting.id
        entries[key] = .connecting(connecting)
        // Detached, so the sign-in's synchronous stretches never hold this actor.
        connecting.task = Task.detached(priority: .userInitiated) {
            let result: Result<Session, any Error>
            do {
                result = .success(try await make())
            } catch {
                result = .failure(error)
            }
            await self.finish(key, connectingId: connectingId, result: result)
        }
        let session = try await wait(on: connecting, key: key, token: token, deadline: deadline, timedOut: timedOut)
        return Lease(session: session, token: token, reused: false)
    }

    // A token this key's live session does not hold is ignored, so a lease of a session that died and was
    // replaced never drops a holder of the new one.
    func release(_ key: Key, token: UUID) {
        guard case .live(let session, var holders)? = entries[key], holders.remove(token) != nil else { return }
        if holders.isEmpty {
            entries[key] = nil
            session.close()
        } else {
            entries[key] = .live(session, holders: holders)
        }
    }

    // The session died; the next acquire builds a new one.
    func forget(_ key: Key, session: Session) {
        guard case .live(let current, _)? = entries[key], current === session else { return }
        entries[key] = nil
    }

    func closeAll() {
        let current = entries
        entries.removeAll()
        for entry in current.values {
            switch entry {
            case .live(let session, _):
                session.close()
            case .connecting(let connecting):
                connecting.task?.cancel()
                let waiters = connecting.waiters
                connecting.waiters.removeAll()
                waiters.values.forEach { $0.resume(throwing: CancellationError()) }
            }
        }
    }

    func waiterCount(_ key: Key) -> Int {
        guard case .connecting(let connecting)? = entries[key] else { return 0 }
        return connecting.waiters.count
    }

    var liveSessionCount: Int {
        entries.values.count(where: { entry in
            if case .live = entry { return true }
            return false
        })
    }

    // MARK: - Private

    private func wait(
        on connecting: Connecting,
        key: Key,
        token: UUID,
        deadline: ContinuousClock.Instant?,
        timedOut: @escaping @Sendable () -> any Error
    ) async throws -> Session {
        let timer = deadline.map { deadline in
            Task {
                try await Task.sleep(until: deadline, clock: .continuous)
                self.withdraw(key, token: token, with: timedOut())
            }
        }
        defer { timer?.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Session, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    withdrawIfIdle(key, connecting: connecting)
                    return
                }
                connecting.waiters[token] = continuation
            }
        } onCancel: {
            Task { await self.withdraw(key, token: token, with: CancellationError()) }
        }
    }

    private func withdraw(_ key: Key, token: UUID, with error: any Error) {
        guard case .connecting(let connecting)? = entries[key],
              let continuation = connecting.waiters.removeValue(forKey: token) else { return }
        continuation.resume(throwing: error)
        withdrawIfIdle(key, connecting: connecting)
    }

    // Nobody waits any more: cancel the sign-in and let the next acquire start its own.
    private func withdrawIfIdle(_ key: Key, connecting: Connecting) {
        guard connecting.waiters.isEmpty, case .connecting(let current)? = entries[key], current === connecting else { return }
        entries[key] = nil
        connecting.task?.cancel()
    }

    // A sign-in whose entry was withdrawn or closed meanwhile has nobody to hand its session to.
    private func finish(_ key: Key, connectingId: UUID, result: Result<Session, any Error>) {
        guard case .connecting(let connecting)? = entries[key], connecting.id == connectingId,
              !connecting.waiters.isEmpty else {
            if case .success(let session) = result { session.close() }
            return
        }
        let waiters = connecting.waiters
        connecting.waiters.removeAll()
        switch result {
        case .success(let session):
            entries[key] = .live(session, holders: Set(waiters.keys))
            waiters.values.forEach { $0.resume(returning: session) }
        case .failure(let error):
            entries[key] = nil
            waiters.values.forEach { $0.resume(throwing: error) }
        }
    }
}
