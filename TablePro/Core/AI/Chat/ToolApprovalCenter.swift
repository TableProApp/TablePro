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

@MainActor
final class ToolApprovalCenter {
    static let shared = ToolApprovalCenter()

    private static let logger = Logger(subsystem: "com.TablePro", category: "ToolApprovalCenter")

    private var pending: [String: CheckedContinuation<ToolApprovalDecision, Never>] = [:]

    func awaitDecision(for toolUseId: String) async -> ToolApprovalDecision {
        await withCheckedContinuation { continuation in
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
        guard let continuation = pending.removeValue(forKey: toolUseId) else { return }
        continuation.resume(returning: decision)
    }

    func cancelAll() {
        let snapshot = pending
        pending.removeAll()
        for (_, continuation) in snapshot {
            continuation.resume(returning: .cancel)
        }
    }

    var hasPending: Bool { !pending.isEmpty }
}
