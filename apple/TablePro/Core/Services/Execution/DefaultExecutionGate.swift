//
//  DefaultExecutionGate.swift
//  TablePro
//

import Foundation
import TableProSQLGrammar

internal actor DefaultExecutionGate: ExecutionGate {
    private let confirming: OperationConfirming
    private let authenticating: OperationAuthenticating
    private let safeModeLevelResolver: @Sendable (UUID) async -> SafeModeLevel
    private let forcesWriteResolver: @Sendable (DatabaseType) async -> Bool
    private let connectionNameResolver: @Sendable (UUID) async -> String?
    private let readOnlyFunctionPolicyResolver: @Sendable (UUID, DatabaseType) async -> ReadOnlyFunctionPolicy
    private let auditLog: any ExecutionAuditLogging

    /// The end of a sentence macOS writes, not a sentence of its own. `LAContext` shows the reason
    /// as "<app> is trying to <reason>.", and the system supplies the closing mark in every
    /// language the app ships: Vietnamese and Chinese continue the same verb ("đang cố gắng %@.",
    /// "正在尝试%@。"), Korean and Turkish put the reason after a colon. So each translation is a
    /// lowercase phrase with no closing period.
    static var authenticationReason: String {
        String(localized: "execute database operations")
    }

    init(
        confirming: OperationConfirming,
        authenticating: OperationAuthenticating,
        safeModeLevelResolver: @escaping @Sendable (UUID) async -> SafeModeLevel,
        forcesWriteResolver: @escaping @Sendable (DatabaseType) async -> Bool,
        connectionNameResolver: @escaping @Sendable (UUID) async -> String? = { _ in nil },
        readOnlyFunctionPolicyResolver: @escaping @Sendable (UUID, DatabaseType) async -> ReadOnlyFunctionPolicy = { _, _ in
            ReadOnlyFunctionPolicy()
        },
        auditLog: any ExecutionAuditLogging = ExecutionAuditLog.shared
    ) {
        self.confirming = confirming
        self.authenticating = authenticating
        self.safeModeLevelResolver = safeModeLevelResolver
        self.forcesWriteResolver = forcesWriteResolver
        self.connectionNameResolver = connectionNameResolver
        self.readOnlyFunctionPolicyResolver = readOnlyFunctionPolicyResolver
        self.auditLog = auditLog
    }

    /// A thin wrapper so every outcome is recorded once. `decide` has seven return points, and a
    /// log call at each is one `return` away from a gap the next change opens silently.
    func authorize(_ request: OperationRequest) async -> OperationDecision {
        let decision = await decide(request)
        await auditLog.record(request: request, decision: decision)
        return decision
    }

    private func decide(_ request: OperationRequest) async -> OperationDecision {
        let level = await safeModeLevelResolver(request.connectionId)
        let caps = request.capabilities

        let tier = request.sql.map { QueryClassifier.classifyTier($0, databaseType: request.databaseType) }
        let isDestructive = request.kind.declaresDestructive
            || request.sql.map { ExternalStatementGate.isDestructive($0, databaseType: request.databaseType) } == true
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
            return .denied(reason: String(
                localized: "Cannot execute write queries: TablePro's Safe Mode is set to read-only for this connection"
            ))
        }

        if level.blocksAllWrites, request.kind != .metadataRead, let sql = request.sql,
           let refusal = await readOnlyFunctionRefusal(request, sql: sql) {
            return refusal
        }

        /// Narrower than `effectiveWrite`, which is true for every statement on a driver that
        /// cannot be opened read-only. A caller asking to confirm its writes means the ones that
        /// actually write, not every `GET` sent to Redis.
        let isWriteStatement = request.kind.declaresWrite || tier == .write || tier == .destructive

        let isMetadataRead = request.kind == .metadataRead
        let needsConfirmation = !isMetadataRead
            && (isDestructive
                || (isWriteStatement && caps.contains(.confirmsWrites))
                || (level.requiresConfirmation && (effectiveWrite || level.appliesToAllQueries)))
        if needsConfirmation, !caps.contains(.preCleared), !caps.contains(.confirmationPreCleared) {
            if caps.contains(.cannotPrompt) {
                return .denied(reason: String(localized: "Confirmation is required for this operation"))
            }
            let confirmed = await confirming.confirm(
                OperationConfirmationRequest(
                    sql: request.sql,
                    operationDescription: request.operationDescription,
                    connectionId: request.connectionId,
                    connectionName: await connectionNameResolver(request.connectionId),
                    databaseType: request.databaseType,
                    caller: request.caller,
                    isDestructive: isDestructive,
                    scope: request.scope,
                    statements: request.statements
                )
            )
            guard confirmed else {
                return .denied(reason: String(localized: "Operation cancelled by user"), cause: .cancelledByUser)
            }
        }

        let needsAuthentication = !isMetadataRead
            && level.requiresAuthentication && (effectiveWrite || level.appliesToAllQueries)
        if needsAuthentication, !caps.contains(.preCleared) {
            if caps.contains(.cannotPrompt) {
                return .denied(reason: String(localized: "Authentication is required for this operation"))
            }
            let authenticated = await authenticating.authenticate(reason: Self.authenticationReason)
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

    // The classifier tiers `SELECT purge_orders()` as a read. Where the driver cannot run it in the engine's read-only
    // mode and a function on the engine can write, a call off the built-in list is asked about, or refused when a
    // profile or the engine floor holds the level, since an answer there would let a write past them. Nil runs it.
    private func readOnlyFunctionRefusal(_ request: OperationRequest, sql: String) async -> OperationDecision? {
        let policy = await readOnlyFunctionPolicyResolver(request.connectionId, request.databaseType)
        guard policy.functionsCanWrite,
              ReadOnlyFunctionCalls.callsUnlistedFunction(sql, databaseType: request.databaseType)
        else { return nil }
        if policy.levelIsHeld {
            return .denied(reason: String(
                localized: "Cannot run this query: it calls a function that can change data, and Safe Mode is held at Read-Only for this connection."
            ))
        }
        let caps = request.capabilities
        guard !caps.contains(.preCleared), !caps.contains(.confirmationPreCleared) else { return nil }
        if caps.contains(.cannotPrompt) {
            return .denied(reason: String(localized: "Confirmation is required for this operation"))
        }
        let confirmed = await confirming.confirm(
            OperationConfirmationRequest(
                sql: request.sql,
                operationDescription: String(localized: "This query calls a function that can change data"),
                connectionId: request.connectionId,
                connectionName: await connectionNameResolver(request.connectionId),
                databaseType: request.databaseType,
                caller: request.caller,
                isDestructive: false,
                scope: request.scope,
                statements: request.statements
            )
        )
        guard confirmed else {
            return .denied(reason: String(localized: "Operation cancelled by user"), cause: .cancelledByUser)
        }
        return nil
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
