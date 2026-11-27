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
    let scope: DatabaseScope?
    // What the confirmation shows, values written in. Empty means `sql` alone.
    let statements: [String]
    // Where a tab's statement runs, which its confirmation does not name: Oracle and Dameng resolve a bare name there.
    let runsIn: DatabaseScope?

    init(
        connectionId: UUID,
        databaseType: DatabaseType,
        sql: String?,
        kind: OperationKind,
        caller: OperationCaller,
        capabilities: CallerCapabilities,
        operationDescription: String,
        scope: DatabaseScope? = nil,
        statements: [String] = [],
        runsIn: DatabaseScope? = nil
    ) {
        self.connectionId = connectionId
        self.databaseType = databaseType
        self.sql = sql
        self.kind = kind
        self.caller = caller
        self.capabilities = capabilities
        self.operationDescription = operationDescription
        self.scope = scope
        self.statements = statements
        self.runsIn = runsIn
    }
}
