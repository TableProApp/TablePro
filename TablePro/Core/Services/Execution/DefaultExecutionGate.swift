//
//  DefaultExecutionGate.swift
//  TablePro
//

import Foundation

internal actor DefaultExecutionGate: ExecutionGate {
    private let confirming: OperationConfirming
    private let authenticating: OperationAuthenticating
    private let safeModeLevelResolver: @Sendable (UUID) async -> SafeModeLevel
    private let forcesWriteResolver: @Sendable (DatabaseType) async -> Bool

    init(
        confirming: OperationConfirming,
        authenticating: OperationAuthenticating,
        safeModeLevelResolver: @escaping @Sendable (UUID) async -> SafeModeLevel,
        forcesWriteResolver: @escaping @Sendable (DatabaseType) async -> Bool
    ) {
        self.confirming = confirming
        self.authenticating = authenticating
        self.safeModeLevelResolver = safeModeLevelResolver
        self.forcesWriteResolver = forcesWriteResolver
    }

    func authorize(_ request: OperationRequest) async -> OperationDecision {
        let level = await safeModeLevelResolver(request.connectionId)
        let caps = request.capabilities

        let tier = request.sql.map { QueryClassifier.classifyTier($0, databaseType: request.databaseType) }
        let isDangerous = request.sql.map { QueryClassifier.isDangerousQuery($0, databaseType: request.databaseType) } ?? false
        let isDestructive = request.kind.declaresDestructive || tier == .destructive || isDangerous
        let isMultiStatement = request.sql.map {
            QueryClassifier.isMultiStatement($0, databaseType: request.databaseType)
        } ?? false
        let effectiveWrite = await resolveEffectiveWrite(request, tier: tier)

        if let denial = capabilityDenial(
            effectiveWrite: effectiveWrite,
            isDestructive: isDestructive,
            isMultiStatement: isMultiStatement,
            caps: caps
        ) {
            return .denied(reason: denial)
        }

        if level.blocksAllWrites, effectiveWrite {
            return .denied(reason: String(localized: "Cannot execute write queries: connection is read-only"))
        }

        let isMetadataRead = request.kind == .metadataRead
        let needsConfirmation = !isMetadataRead
            && (isDestructive || (level.requiresConfirmation && (effectiveWrite || level.appliesToAllQueries)))
        if needsConfirmation, !caps.contains(.preCleared), !caps.contains(.confirmationPreCleared) {
            if caps.contains(.cannotPrompt) {
                return .denied(reason: String(localized: "Confirmation is required for this operation"))
            }
            let confirmed = await confirming.confirm(
                sql: request.sql ?? "",
                operationDescription: request.operationDescription,
                connectionId: request.connectionId,
                isDestructive: isDestructive
            )
            guard confirmed else {
                return .denied(reason: String(localized: "Operation cancelled by user"))
            }
        }

        let needsAuthentication = !isMetadataRead
            && level.requiresAuthentication && (effectiveWrite || level.appliesToAllQueries)
        if needsAuthentication, !caps.contains(.preCleared) {
            if caps.contains(.cannotPrompt) {
                return .denied(reason: String(localized: "Authentication is required for this operation"))
            }
            let authenticated = await authenticating.authenticate(
                reason: String(localized: "Authenticate to execute database operations")
            )
            guard authenticated else {
                return .denied(reason: String(localized: "Authentication required to execute write operations"))
            }
        }

        return .authorized(
            OperationReceipt(
                connectionId: request.connectionId,
                kind: request.kind,
                effectiveWrite: effectiveWrite,
                grantedAt: Date(),
                token: UUID()
            )
        )
    }

    private func resolveEffectiveWrite(_ request: OperationRequest, tier: QueryTier?) async -> Bool {
        if request.kind == .metadataRead {
            return false
        }
        if request.kind.declaresWrite {
            return true
        }
        if tier == .write || tier == .destructive {
            return true
        }
        return await forcesWriteResolver(request.databaseType)
    }

    private func capabilityDenial(
        effectiveWrite: Bool,
        isDestructive: Bool,
        isMultiStatement: Bool,
        caps: CallerCapabilities
    ) -> String? {
        if isDestructive, !caps.contains(.mayRunDestructive) {
            return String(localized: "Destructive operations are not permitted for this client")
        }
        if effectiveWrite, !caps.contains(.mayWrite) {
            return String(localized: "Write operations are not permitted for this client")
        }
        if isMultiStatement, !caps.contains(.mayRunMultiStatement) {
            return String(localized: "Multiple statements are not permitted for this client")
        }
        return nil
    }
}
