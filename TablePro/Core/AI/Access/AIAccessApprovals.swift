//
//  AIAccessApprovals.swift
//  TablePro
//

import Foundation

@MainActor
final class AIAccessApprovals {
    static let shared = AIAccessApprovals()

    private var approvedConnectionIds: Set<UUID> = []

    func approve(_ connectionId: UUID) {
        approvedConnectionIds.insert(connectionId)
    }

    func isApproved(_ connectionId: UUID) -> Bool {
        approvedConnectionIds.contains(connectionId)
    }

    func revoke(_ connectionId: UUID) {
        approvedConnectionIds.remove(connectionId)
    }
}
