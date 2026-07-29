//
//  ExecutionGate.swift
//  TablePro
//

import Foundation

internal protocol ExecutionGate: Sendable {
    func authorize(_ request: OperationRequest) async -> OperationDecision
}

internal extension ExecutionGate {
    func authorizing<T>(_ request: OperationRequest, perform body: () async throws -> T) async throws -> T {
        let decision = await authorize(request)
        guard case .authorized(let receipt) = decision else {
            throw ExecutionGateError.denied(decision.deniedReason ?? String(localized: "Operation not permitted"))
        }
        return try await AuthorizationReceiptBox.$current.withValue(receipt) {
            try await body()
        }
    }
}
