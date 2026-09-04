//
//  ProviderStreamLease.swift
//  TablePro
//

import Foundation
import os

/// One streaming turn at a time per provider configuration.
///
/// `AIProviderFactory` caches one `ChatTransport` per config id and hands the same instance to
/// everyone. That is fine for a stateless HTTP provider and wrong for `CopilotChatProvider`, which
/// holds a server-side `conversationId`: two sessions on one config interleave their turns into one
/// upstream conversation, and one session's New Conversation resets the other's mid-stream.
///
/// Keying the transport cache per session is the fuller fix and is deliberately not that. Copilot's
/// state lives on the server, so a per-session cache entry still needs per-session conversation
/// handling upstream. A queue is the smaller change that makes the failure impossible rather than
/// unlikely, and the wait is reported so the session rail can say why a session is not moving.
@MainActor
internal final class ProviderStreamLease {
    internal static let shared = ProviderStreamLease()

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "ProviderStreamLease")

    /// The session currently streaming on each config, and who is waiting behind it. Order is
    /// preserved so the queue is first-come rather than whichever continuation the dictionary
    /// happened to yield.
    private var holder: [UUID: UUID] = [:]
    private var waiters: [UUID: [(sessionId: UUID, continuation: CheckedContinuation<Void, Never>)]] = [:]

    internal init() {}

    /// Held for the duration of one turn. A session that already holds the lease for a config takes
    /// it again without waiting, because a tool roundtrip is several requests inside one turn and a
    /// re-entrant acquire would deadlock against itself.
    internal func acquire(configId: UUID, sessionId: UUID) async {
        if holder[configId] == nil || holder[configId] == sessionId {
            holder[configId] = sessionId
            return
        }
        await withCheckedContinuation { continuation in
            waiters[configId, default: []].append((sessionId, continuation))
            Self.logger.info(
                """
                Session \(sessionId, privacy: .public) queued behind \
                \(self.holder[configId]?.uuidString ?? "unknown", privacy: .public) on provider \
                \(configId, privacy: .public)
                """
            )
        }
    }

    /// Releasing hands the lease straight to the next waiter rather than clearing it, so a third
    /// session cannot jump the queue between the release and the wake.
    internal func release(configId: UUID, sessionId: UUID) {
        guard holder[configId] == sessionId else { return }
        guard var queue = waiters[configId], !queue.isEmpty else {
            holder.removeValue(forKey: configId)
            return
        }
        let next = queue.removeFirst()
        waiters[configId] = queue.isEmpty ? nil : queue
        holder[configId] = next.sessionId
        next.continuation.resume()
    }

    /// A session going away releases what it holds and leaves the queue it is standing in. Without
    /// the second half, a session torn down while queued would never be resumed and its turn would
    /// hang for the life of the app.
    internal func releaseAll(sessionId: UUID) {
        /// Snapshotted before the loops, because `release` writes both dictionaries and iterating a
        /// stored property while mutating it reads as safe only by accident of copy-on-write.
        let heldConfigs = holder.filter { $0.value == sessionId }.map(\.key)
        for configId in heldConfigs {
            release(configId: configId, sessionId: sessionId)
        }
        let queuedConfigs = Array(waiters.keys)
        for configId in queuedConfigs {
            guard var queue = waiters[configId] else { continue }
            let leaving = queue.filter { $0.sessionId == sessionId }
            guard !leaving.isEmpty else { continue }
            queue.removeAll { $0.sessionId == sessionId }
            waiters[configId] = queue.isEmpty ? nil : queue
            for entry in leaving {
                entry.continuation.resume()
            }
        }
    }

    /// Runs `body` with the lease held, taking it first unless this session already holds it.
    /// The re-entrancy check is what keeps a reset issued mid-turn from releasing the lease out
    /// from under the turn that is still running.
    internal func withLease(configId: UUID, sessionId: UUID, _ body: () -> Void) async {
        let alreadyHeld = holder[configId] == sessionId
        if !alreadyHeld {
            await acquire(configId: configId, sessionId: sessionId)
        }
        body()
        if !alreadyHeld {
            release(configId: configId, sessionId: sessionId)
        }
    }

    internal func holdingSession(configId: UUID) -> UUID? {
        holder[configId]
    }

    internal func isWaiting(sessionId: UUID) -> Bool {
        waiters.values.contains { queue in queue.contains { $0.sessionId == sessionId } }
    }

    /// What the rail shows next to a queued session. Nil when the session is not waiting.
    internal func waitReason(sessionId: UUID, providerName: (UUID) -> String?) -> String? {
        for (configId, queue) in waiters where queue.contains(where: { $0.sessionId == sessionId }) {
            return Self.waitMessage(providerName: providerName(configId))
        }
        return nil
    }

    /// The same sentence for a session that is about to queue, before it has joined the queue and
    /// can be found by `waitReason`.
    internal static func waitMessage(providerName: String?) -> String {
        guard let providerName, !providerName.isEmpty else {
            return String(localized: "Waiting for another session on the same provider")
        }
        return String(
            format: String(localized: "Waiting for another session on %@"),
            providerName
        )
    }
}
