//
//  ToolApprovalCenter.swift
//  TablePro
//

import Foundation
import os

enum ToolApprovalDecision: Sendable {
    case run
    case alwaysAllow
    case cancel
}

/// Which call an answer is about.
///
/// The provider's own id is not enough on its own. Several endpoints number every turn's calls from
/// `call_0`, so two sessions streaming at once can both be waiting on `call_0`: one session's click
/// resolved the other's statement, and either session stopping cancelled both. The session is what
/// makes the key unique, and it is what `cancelAll` scopes to.
struct ApprovalRequestID: Hashable, Sendable {
    let sessionId: UUID
    let toolUseId: String
}

/// Where a tool call waits for the user's answer.
///
/// A turn can propose several calls at once, and the transcript draws a card for every one of them
/// the moment they arrive. The stream, though, awaits them one at a time, so only the first had a
/// continuation registered: clicking Run on the second card hit the missing-continuation guard and
/// did nothing at all, silently, while the stream stayed parked on the first. Two things fix that.
/// Every waiting call is announced with `expect(_:)` before any of them is awaited, and a decision
/// that arrives before its own await is buffered rather than dropped.
///
/// The buffer is bounded to the turn that opened it, because a transcript restored from disk still
/// carries its `.pending` cards: a click on one of those would otherwise pre-approve a later write
/// with no card shown at all.
@MainActor
final class ToolApprovalCenter {
    static let shared = ToolApprovalCenter()

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "ToolApprovalCenter")

    private var pending: [ApprovalRequestID: CheckedContinuation<ToolApprovalDecision, Never>] = [:]
    private var expected: Set<ApprovalRequestID> = []
    private var decided: [ApprovalRequestID: ToolApprovalDecision] = [:]

    /// Announces the calls this turn will await, so a decision on any of them is honoured from the
    /// moment its card is on screen rather than from the moment the stream reaches it.
    func expect(sessionId: UUID, toolUseIds: [String]) {
        expected.formUnion(toolUseIds.map { ApprovalRequestID(sessionId: sessionId, toolUseId: $0) })
    }

    /// Releases a turn's claim on its ids, whatever happened to them.
    func forget(sessionId: UUID, toolUseIds: [String]) {
        for id in toolUseIds.map({ ApprovalRequestID(sessionId: sessionId, toolUseId: $0) }) {
            expected.remove(id)
            decided.removeValue(forKey: id)
        }
    }

    func awaitDecision(sessionId: UUID, toolUseId: String) async -> ToolApprovalDecision {
        let key = ApprovalRequestID(sessionId: sessionId, toolUseId: toolUseId)
        if let early = decided.removeValue(forKey: key) {
            return early
        }
        return await withCheckedContinuation { continuation in
            if let existing = pending[key] {
                Self.logger.warning(
                    "Duplicate awaitDecision for \(toolUseId, privacy: .public); cancelling prior continuation"
                )
                existing.resume(returning: .cancel)
            }
            pending[key] = continuation
        }
    }

    func resolve(sessionId: UUID, toolUseId: String, decision: ToolApprovalDecision) {
        let key = ApprovalRequestID(sessionId: sessionId, toolUseId: toolUseId)
        if let continuation = pending.removeValue(forKey: key) {
            continuation.resume(returning: decision)
            return
        }
        guard expected.contains(key) else {
            Self.logger.warning(
                "Discarded a decision for \(toolUseId, privacy: .public), which no turn is waiting on"
            )
            return
        }
        decided[key] = decision
    }

    /// Resumes one session's waiting calls as cancelled, and answers the ones it has not reached.
    ///
    /// Scoped to a session. One session stopping used to cancel every other session's pending
    /// approvals as well, which is the whole reason several sessions could not run at once.
    ///
    /// A turn awaits its cards one at a time, so the later ones are announced but not yet awaited.
    /// Clearing them outright left the loop free to install a fresh continuation for the next card
    /// after the first resumed, and sit there for good. They are answered instead.
    func cancelAll(sessionId: UUID) {
        let owned = pending.filter { $0.key.sessionId == sessionId }
        for key in owned.keys {
            pending.removeValue(forKey: key)
        }
        for key in expected where key.sessionId == sessionId {
            decided[key] = .cancel
        }
        for (_, continuation) in owned {
            continuation.resume(returning: .cancel)
        }
    }

    /// Every session, for app teardown alone.
    func cancelEverything() {
        let snapshot = pending
        pending.removeAll()
        decided.removeAll()
        for key in expected {
            decided[key] = .cancel
        }
        for (_, continuation) in snapshot {
            continuation.resume(returning: .cancel)
        }
    }

    func hasPending(sessionId: UUID) -> Bool {
        pending.keys.contains { $0.sessionId == sessionId }
            || expected.contains { key in
                key.sessionId == sessionId && decided[key] == nil
            }
    }

    var hasPending: Bool { !pending.isEmpty }
}
