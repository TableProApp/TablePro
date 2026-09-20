import Foundation
import Observation
import os
import TableProDatabase

/// A question a connect attempt has to ask the user, shown by the screen that owns the attempt.
///
/// The queue is per attempt owner rather than app-wide, and it answers every waiter: an attempt
/// that is cancelled, or whose screen goes away, resolves its question instead of leaving the
/// tunnel suspended on a prompt nobody can see.
/// How many screens are waiting on one connect attempt.
///
/// An attempt belongs to the screens awaiting it: the last one to leave abandons it, so a reopened
/// connection never joins an attempt the user walked away from. A screen replaced by another while
/// the attempt runs must not cancel it, which is why this counts rather than latches.
nonisolated struct AttemptWaiters: Equatable {
    private(set) var waiting = 0

    var isAwaited: Bool { waiting > 0 }

    var isIdle: Bool { !isAwaited }

    mutating func join() {
        waiting += 1
    }

    /// True when the caller that left was the last one waiting.
    mutating func leave() -> Bool {
        waiting = max(0, waiting - 1)
        return isIdle
    }
}

@MainActor
@Observable
final class ConnectionPromptQueue: ConnectionPrompter {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionPrompt")

    private(set) var pending: [ConnectionPrompt] = []
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    var current: ConnectionPrompt? { pending.first }

    nonisolated init() {}

    /// A notice states something and carries a single button, so it can never stand in for a yes.
    func confirm(_ prompt: ConnectionPrompt) async -> Bool {
        guard prompt.style != .notice else {
            Self.logger.error("A notice was asked as a question, which cannot be answered")
            return false
        }
        guard !Task.isCancelled else { return false }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                pending.append(prompt)
                waiters[prompt.id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.answer(prompt.id, accepted: false)
            }
        }
    }

    func notify(_ prompt: ConnectionPrompt) {
        pending.append(prompt)
    }

    func answer(_ id: UUID, accepted: Bool) {
        pending.removeAll { $0.id == id }
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        Self.logger.info("Connection prompt answered: \(accepted, privacy: .public)")
        waiter.resume(returning: accepted)
    }

    func cancelAll() {
        let cancelled = pending
        pending.removeAll()
        for prompt in cancelled {
            waiters.removeValue(forKey: prompt.id)?.resume(returning: false)
        }
        for (_, waiter) in waiters { waiter.resume(returning: false) }
        waiters.removeAll()
    }
}
