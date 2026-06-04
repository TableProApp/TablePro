//
//  DatabaseDriver+ExecutionGate.swift
//  TablePro
//

import Foundation

extension DatabaseDriver {
    func executeAuthorizing(
        query: String,
        request: OperationRequest,
        gate: ExecutionGate = ExecutionGateProvider.shared
    ) async throws -> QueryResult {
        try await runAuthorizing(request: request, gate: gate) {
            try await self.execute(query: query)
        }
    }

    func executeParameterizedAuthorizing(
        query: String,
        parameters: [Any?],
        request: OperationRequest,
        gate: ExecutionGate = ExecutionGateProvider.shared
    ) async throws -> QueryResult {
        try await runAuthorizing(request: request, gate: gate) {
            try await self.executeParameterized(query: query, parameters: parameters)
        }
    }

    func executeUserQueryAuthorizing(
        query: String,
        rowCap: Int?,
        parameters: [Any?]?,
        request: OperationRequest,
        gate: ExecutionGate = ExecutionGateProvider.shared
    ) async throws -> QueryResult {
        try await runAuthorizing(request: request, gate: gate) {
            try await self.executeUserQuery(query: query, rowCap: rowCap, parameters: parameters)
        }
    }

    private func runAuthorizing<T>(
        request: OperationRequest,
        gate: ExecutionGate,
        perform body: () async throws -> T
    ) async throws -> T {
        if AuthorizationReceiptBox.current?.covers(request) == true {
            return try await body()
        }
        return try await gate.authorizing(request, perform: body)
    }
}

private extension OperationReceipt {
    func covers(_ request: OperationRequest) -> Bool {
        connectionId == request.connectionId && kind.covers(request.kind)
    }
}

private extension OperationKind {
    func covers(_ requested: OperationKind) -> Bool {
        if self == requested { return true }
        if self == .metadataRead { return requested == .metadataRead }
        if self == .destructiveQuery { return true }
        if declaresWrite { return requested != .destructiveQuery && requested != .metadataRead }
        return !requested.declaresWrite
    }
}
