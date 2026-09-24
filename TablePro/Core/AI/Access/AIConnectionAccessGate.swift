//
//  AIConnectionAccessGate.swift
//  TablePro
//

import Foundation

@MainActor
struct AIConnectionAccessGate {
    typealias PolicyLookup = @MainActor (UUID) -> AIConnectionPolicy?

    private let approvals: AIAccessApprovals
    private let currentPolicy: PolicyLookup

    init(approvals: AIAccessApprovals, currentPolicy: @escaping PolicyLookup) {
        self.approvals = approvals
        self.currentPolicy = currentPolicy
    }

    func allowsUnpromptedAccess(to connectionId: UUID?) -> Bool {
        guard let connectionId, let policy = currentPolicy(connectionId) else { return false }
        switch policy {
        case .alwaysAllow:
            return true
        case .askEachTime:
            return approvals.isApproved(connectionId)
        case .never:
            return false
        }
    }
}

extension AIConnectionAccessGate {
    static var live: AIConnectionAccessGate {
        savedPolicy(
            connectionStorage: .shared,
            databaseManager: .shared,
            approvals: .shared,
            defaultPolicy: { AppSettingsManager.shared.ai.defaultConnectionPolicy }
        )
    }

    static func savedPolicy(
        connectionStorage: ConnectionStorage,
        databaseManager: DatabaseManager,
        approvals: AIAccessApprovals,
        defaultPolicy: @escaping @MainActor () -> AIConnectionPolicy
    ) -> AIConnectionAccessGate {
        AIConnectionAccessGate(approvals: approvals) { connectionId in
            let record = connectionStorage.loadConnection(id: connectionId)
                ?? databaseManager.session(for: connectionId)?.connection
            guard let record else { return nil }
            return record.aiPolicy ?? defaultPolicy()
        }
    }
}
