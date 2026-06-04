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

internal extension OperationRequest {
    static func interactiveUser(
        connectionId: UUID,
        databaseType: DatabaseType,
        sql: String?,
        kind: OperationKind? = nil,
        capabilities: CallerCapabilities = .interactiveUser,
        operationDescription: String
    ) -> OperationRequest {
        OperationRequest(
            connectionId: connectionId,
            databaseType: databaseType,
            sql: sql,
            kind: resolvedKind(sql: sql, databaseType: databaseType, explicitKind: kind, fallback: .readQuery),
            caller: .userInterface,
            capabilities: capabilities,
            operationDescription: operationDescription
        )
    }

    static func metadataRead(
        connectionId: UUID,
        databaseType: DatabaseType,
        sql: String,
        caller: OperationCaller = .userInterface,
        operationDescription: String
    ) -> OperationRequest {
        OperationRequest(
            connectionId: connectionId,
            databaseType: databaseType,
            sql: sql,
            kind: .metadataRead,
            caller: caller,
            capabilities: [.mayWrite, .mayRunDestructive, .mayRunMultiStatement, .cannotPrompt],
            operationDescription: operationDescription
        )
    }

    static func backgroundMaintenance(
        connectionId: UUID,
        databaseType: DatabaseType,
        sql: String?,
        kind: OperationKind? = nil,
        operationDescription: String
    ) -> OperationRequest {
        OperationRequest(
            connectionId: connectionId,
            databaseType: databaseType,
            sql: sql,
            kind: resolvedKind(sql: sql, databaseType: databaseType, explicitKind: kind, fallback: .maintenance),
            caller: .backgroundMaintenance,
            capabilities: [.mayWrite, .mayRunDestructive, .mayRunMultiStatement, .cannotPrompt],
            operationDescription: operationDescription
        )
    }

    static func importPipeline(
        connectionId: UUID,
        databaseType: DatabaseType,
        sql: String?,
        kind: OperationKind? = nil,
        operationDescription: String
    ) -> OperationRequest {
        OperationRequest(
            connectionId: connectionId,
            databaseType: databaseType,
            sql: sql,
            kind: resolvedKind(sql: sql, databaseType: databaseType, explicitKind: kind, fallback: .importData),
            caller: .importPipeline,
            capabilities: .interactiveUser,
            operationDescription: operationDescription
        )
    }

    static func mcpClient(
        connectionId: UUID,
        databaseType: DatabaseType,
        sql: String,
        kind: OperationKind? = nil,
        capabilities: CallerCapabilities,
        label: String? = nil,
        operationDescription: String
    ) -> OperationRequest {
        OperationRequest(
            connectionId: connectionId,
            databaseType: databaseType,
            sql: sql,
            kind: resolvedKind(sql: sql, databaseType: databaseType, explicitKind: kind, fallback: .readQuery),
            caller: .mcpClient(label: label),
            capabilities: capabilities,
            operationDescription: operationDescription
        )
    }

    private static func resolvedKind(
        sql: String?,
        databaseType: DatabaseType,
        explicitKind: OperationKind?,
        fallback: OperationKind
    ) -> OperationKind {
        if let explicitKind {
            return explicitKind
        }
        guard let sql else {
            return fallback
        }
        return OperationKind.worst(of: [sql], databaseType: databaseType)
    }
}
