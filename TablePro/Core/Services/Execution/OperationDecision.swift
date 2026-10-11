//
//  OperationDecision.swift
//  TablePro
//

import Foundation

internal struct OperationReceipt: Sendable, Equatable {
    let connectionId: UUID
    let kind: OperationKind
    let effectiveWrite: Bool
    let grantedAt: Date
    fileprivate let token: UUID

    init(connectionId: UUID, kind: OperationKind, effectiveWrite: Bool, grantedAt: Date, token: UUID) {
        self.connectionId = connectionId
        self.kind = kind
        self.effectiveWrite = effectiveWrite
        self.grantedAt = grantedAt
        self.token = token
    }
}

/// Why the gate said no. Only the gate knows whether the person at the keyboard answered Cancel or
/// a rule refused them, and a caller needs that to stay quiet after a Cancel rather than report the
/// user's own choice back to them as a failure.
internal enum OperationDenialCause: Sendable, Equatable {
    case policy
    case cancelledByUser
}

internal enum OperationDecision: Sendable {
    case authorized(OperationReceipt)
    case denied(reason: String, cause: OperationDenialCause = .policy)
}

internal extension OperationDecision {
    var isAuthorized: Bool {
        if case .authorized = self {
            return true
        }
        return false
    }

    var deniedReason: String? {
        if case .denied(let reason, _) = self {
            return reason
        }
        return nil
    }

    /// What a caller that throws its denial raises, with a Cancel kept apart from a refusal.
    var denialError: ExecutionGateError? {
        guard case .denied(let reason, let cause) = self else { return nil }
        switch cause {
        case .policy:
            return .denied(reason)
        case .cancelledByUser:
            return .cancelledByUser(reason)
        }
    }
}

internal enum ExecutionGateError: LocalizedError {
    case denied(String)
    case cancelledByUser(String)

    var errorDescription: String? {
        switch self {
        case .denied(let reason), .cancelledByUser(let reason):
            return reason
        }
    }
}
