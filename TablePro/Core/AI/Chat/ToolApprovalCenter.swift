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

/// Where a tool call waits for the user's answer.
///
/// A turn can propose several calls at once, and the transcript draws a card for every one of them
/// the moment they arrive. The stream, though, awaits them one at a time, so only the first had a
/// continuation registered: clicking Run on the second card hit the missing-continuation guard and
/// did nothing at all, silently, while the stream stayed parked on the first. Two things fix that.
/// Every waiting call is announced with `expect(_:)` before any of them is awaited, and a decision
/// that arrives before its own await is buffered rather than dropped.
///
/// The buffer is bounded to the turn that opened it. `ToolUseBlock.id` is whatever the provider
/// called it, and several providers reuse `call_0` in every turn, so a decision left lying around
/// would be spent on an unrelated call later in the conversation. That matters beyond tidiness: a
/// transcript restored from disk still carries its `.pending` cards, so a click on one of those
/// would otherwise pre-approve the next turn's write with no card shown at all.
@MainActor
final class ToolApprovalCenter {
    static let shared = ToolApprovalCenter()

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "ToolApprovalCenter")

    private var pending: [String: CheckedContinuation<ToolApprovalDecision, Never>] = [:]
    private var expected: Set<String> = []
    private var decided: [String: ToolApprovalDecision] = [:]

    /// Announces the calls this turn will await, so a decision on any of them is honoured from the
    /// moment its card is on screen rather than from the moment the stream reaches it.
    func expect(_ toolUseIds: [String]) {
        expected.formUnion(toolUseIds)
    }

    /// Releases a turn's claim on its ids, whatever happened to them. Called once the turn's
    /// approvals are settled so a provider that reuses an id cannot inherit an answer.
    func forget(_ toolUseIds: [String]) {
        expected.subtract(toolUseIds)
        for id in toolUseIds {
            decided.removeValue(forKey: id)
        }
    }

    func awaitDecision(for toolUseId: String) async -> ToolApprovalDecision {
        if let early = decided.removeValue(forKey: toolUseId) {
            return early
        }
        return await withCheckedContinuation { continuation in
            if let existing = pending[toolUseId] {
                Self.logger.warning(
                    "Duplicate awaitDecision for tool use id \(toolUseId, privacy: .public); cancelling prior continuation"
                )
                existing.resume(returning: .cancel)
            }
            pending[toolUseId] = continuation
        }
    }

    func resolve(toolUseId: String, decision: ToolApprovalDecision) {
        if let continuation = pending.removeValue(forKey: toolUseId) {
            continuation.resume(returning: decision)
            return
        }
        guard expected.contains(toolUseId) else {
            Self.logger.warning(
                "Discarded a decision for \(toolUseId, privacy: .public), which no turn is waiting on"
            )
            return
        }
        decided[toolUseId] = decision
    }

    /// Resumes everything still waiting as cancelled, and answers everything not waiting yet.
    ///
    /// Teardown has to reach this. A streaming task suspended inside `awaitDecision` holds the
    /// provider, its open stream and the whole turn, and cancelling the task does not resume a
    /// continuation, so a window closed over a card on screen leaked all of it for the life of the
    /// process.
    ///
    /// A turn awaits its cards one at a time, so the later ones are announced but not yet awaited.
    /// Clearing them outright left the loop free to install a fresh continuation for the next card
    /// after the first resumed, and sit there for good. They are answered instead.
    func cancelAll() {
        let snapshot = pending
        pending.removeAll()
        decided.removeAll()
        for id in expected {
            decided[id] = .cancel
        }
        for (_, continuation) in snapshot {
            continuation.resume(returning: .cancel)
        }
    }

    var hasPending: Bool { !pending.isEmpty }
}
