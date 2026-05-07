//
//  ToolApprovalCenter.swift
//  TablePro
//

import Foundation

enum ToolApprovalDecision: Sendable {
    case run
    case alwaysAllow
    case cancel
}

@MainActor
final class ToolApprovalCenter {
    static let shared = ToolApprovalCenter()

    private var pending: [String: CheckedContinuation<ToolApprovalDecision, Never>] = [:]

    func awaitDecision(for toolUseId: String) async -> ToolApprovalDecision {
        await withCheckedContinuation { continuation in
            if let existing = pending[toolUseId] {
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
