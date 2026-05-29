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

internal enum OperationDecision: Sendable {
    case authorized(OperationReceipt)
    case denied(reason: String)
}

internal extension OperationDecision {
    var isAuthorized: Bool {
        if case .authorized = self {
            return true
        }
        return false
    }

    var deniedReason: String? {
        if case .denied(let reason) = self {
            return reason
        }
        return nil
    }
}

internal enum ExecutionGateError: LocalizedError {
    case denied(String)

    var errorDescription: String? {
        switch self {
        case .denied(let reason):
            return reason
        }
    }
}
