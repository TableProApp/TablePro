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
            policy(
                for: connectionId,
                connectionStorage: connectionStorage,
                databaseManager: databaseManager,
                defaultPolicy: defaultPolicy()
            )
        }
    }

    /// The saved record wins: a live session keeps the policy it connected with. Only a connection
    /// with no saved record answers with its session's copy, then `unsavedCopy`. Nil refuses, and a
    /// connections file that will not decode refuses rather than fall back to an older copy.
    static func policy(
        for connectionId: UUID,
        connectionStorage: ConnectionStorage,
        databaseManager: DatabaseManager,
        defaultPolicy: AIConnectionPolicy,
        unsavedCopy: DatabaseConnection? = nil
    ) -> AIConnectionPolicy? {
        if let saved = connectionStorage.loadConnection(id: connectionId) {
            return saved.aiPolicy ?? defaultPolicy
        }
        guard !connectionStorage.lastLoadFailed else { return nil }
        guard let unsaved = databaseManager.session(for: connectionId)?.connection ?? unsavedCopy else {
            return nil
        }
        return unsaved.aiPolicy ?? defaultPolicy
    }
}
