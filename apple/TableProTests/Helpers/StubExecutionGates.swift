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
import TableProMCP
import TableProSQLGrammar

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

internal actor RequestRecordingGate: ExecutionGate {
    private(set) var requests: [OperationRequest] = []
    private let allows: Bool

    internal init(allows: Bool) {
        self.allows = allows
    }

    internal func authorize(_ request: OperationRequest) async -> OperationDecision {
        requests.append(request)
        guard allows else { return .denied(reason: "Refused by the test") }
        return await AlwaysAllowGate().authorize(request)
    }
}

// An operation approved the way a tool gets one, for a test that drives the bridge directly.
internal enum ApprovedOperationFixture {
    internal static func approve(
        _ statements: [OperationStatement],
        scope: DatabaseScope,
        databaseType: DatabaseType,
        kind: OperationKind? = nil,
        unit: OperationUnit = .statement,
        capabilities: CallerCapabilities = [.mayWrite, .mayRunDestructive, .mayRunMultiStatement]
    ) async throws -> ApprovedOperation {
        let graded = statements.count == 1 ? statements.first?.sql : nil
        let tier = graded.map { QueryClassifier.classifyTier($0, databaseType: databaseType) } ?? .safe
        return try await ExternalStatementGate.approve(
            PendingOperation(
                scope: scope,
                databaseType: databaseType,
                statements: statements,
                kind: kind ?? OperationKind.from(tier),
                unit: unit,
                caller: .mcpClient(label: "tests"),
                capabilities: capabilities,
                operationDescription: "test"
            ),
            gate: AlwaysAllowGate()
        )
    }
}

// Plan, approve and run, as every external caller does; the bridge itself takes only an approved operation.
extension DatabaseAccessBridge {
    func runStatement(
        scope: DatabaseScope,
        query: String,
        maxRows: Int,
        timeoutSeconds: Int,
        cancellation: (any StatementCancellationSignal)?,
        masking: ExternalRowMasking = .byOrigin
    ) async throws -> StatementOutcome {
        let statement = try await plannedStatement(scope: scope, query: query, maxRows: maxRows)
        let databaseType = try await ensureConnected(scope.connectionId)
        let operation = try await ApprovedOperationFixture.approve([statement], scope: scope, databaseType: databaseType)
        return try await runStatement(
            operation,
            maxRows: maxRows,
            timeoutSeconds: timeoutSeconds,
            cancellation: cancellation,
            masking: masking
        )
    }

    func runScript(
        scope: DatabaseScope,
        query: String,
        maxRows: Int,
        timeoutSeconds: Int,
        cancellation: (any StatementCancellationSignal)?
    ) async throws -> ScriptOutcome {
        let planned = try await plannedScript(scope: scope, query: query, maxRows: maxRows)
        let databaseType = try await ensureConnected(scope.connectionId)
        let operation = try await ApprovedOperationFixture.approve(
            [planned.statement], scope: scope, databaseType: databaseType, unit: planned.unit
        )
        return try await runScript(operation, maxRows: maxRows, timeoutSeconds: timeoutSeconds, cancellation: cancellation)
    }
}

extension MCPConnectionBridge {
    func executeQuery(
        scope: DatabaseScope,
        query: String,
        maxRows: Int,
        timeoutSeconds: Int,
        cancellation: MCPCancellationToken?
    ) async throws -> JsonValue {
        let statement = try await plannedStatement(scope: scope, query: query, maxRows: maxRows)
        let databaseType = try await ensureConnected(scope.connectionId)
        let operation = try await ApprovedOperationFixture.approve([statement], scope: scope, databaseType: databaseType)
        return try await executeQuery(
            operation,
            maxRows: maxRows,
            timeoutSeconds: timeoutSeconds,
            cancellation: cancellation
        )
    }
}
