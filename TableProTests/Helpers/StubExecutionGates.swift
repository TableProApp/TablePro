//
//  StubExecutionGates.swift
//  TableProTests
//
//  The real gate confirms a destructive statement with an NSAlert, and an alert raised with no
//  window runs application-modal. Nothing answers it on a CI runner, so a test that reaches the
//  real gate stops the whole job there. Every test that drives a gated operation supplies one of
//  these instead and asserts on what ran, not on who was asked.
//

import Foundation
@testable import TablePro

internal struct AlwaysAllowGate: ExecutionGate {
    internal func authorize(_ request: OperationRequest) async -> OperationDecision {
        .authorized(OperationReceipt(
            connectionId: request.connectionId,
            kind: request.kind,
            effectiveWrite: true,
            grantedAt: Date(),
            token: UUID()
        ))
    }
}

internal struct AlwaysDenyGate: ExecutionGate {
    internal let reason: String

    internal init(reason: String = "Read-Only connection") {
        self.reason = reason
    }

    internal func authorize(_ request: OperationRequest) async -> OperationDecision {
        .denied(reason: reason)
    }
}
