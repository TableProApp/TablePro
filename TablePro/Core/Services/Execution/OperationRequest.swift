//
//  OperationRequest.swift
//  TablePro
//

import Foundation

internal struct OperationRequest: Sendable {
    let connectionId: UUID
    let databaseType: DatabaseType
    let sql: String?
    let kind: OperationKind
    let caller: OperationCaller
    let capabilities: CallerCapabilities
    let operationDescription: String
}
