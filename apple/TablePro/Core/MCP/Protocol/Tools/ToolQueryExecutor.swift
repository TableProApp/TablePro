import Foundation
import TableProMCP

enum ToolQueryExecutor {
    static func executeAndLog(
        services: MCPToolServices,
        operation: ApprovedOperation,
        maxRows: Int,
        timeoutSeconds: Int,
        context: MCPRequestContext,
        secrets: [String],
        masking: ExternalRowMasking = .byOrigin
    ) async throws -> JsonValue {
        try await context.cancellation.throwIfCancelled()
        return try await executeAndLog(
            services: services,
            operation: operation,
            maxRows: maxRows,
            timeoutSeconds: timeoutSeconds,
            principal: context.principal,
            client: MCPAuditLogger.clientName(for: context.meta),
            cancellation: context.cancellation,
            secrets: secrets,
            source: historySource(for: context),
            masking: masking
        )
    }

    // A label from the client's own `clientInfo`, as Connected Clients shows; access is decided by the token.
    static func historySource(for context: MCPRequestContext) -> QueryHistorySource {
        context.meta.clientInfo?.name == CLIClientIdentity.name ? .commandLine : .mcp
    }

    static func executeAndLog(
        services: MCPToolServices,
        operation: ApprovedOperation,
        maxRows: Int,
        timeoutSeconds: Int,
        principal: MCPPrincipal,
        client: String? = nil,
        cancellation: MCPCancellationToken? = nil,
        secrets: [String] = [],
        source: QueryHistorySource = .mcp,
        masking: ExternalRowMasking = .byOrigin
    ) async throws -> JsonValue {
        try await logged(
            services: services,
            approved: operation,
            principal: principal,
            client: client,
            secrets: secrets,
            source: source
        ) {
            try await run(
                operation,
                services: services,
                maxRows: maxRows,
                timeoutSeconds: timeoutSeconds,
                cancellation: cancellation,
                masking: masking
            )
        }
    }

    static func executeResultAndLog(
        services: MCPToolServices,
        operation: ApprovedOperation,
        maxRows: Int,
        timeoutSeconds: Int,
        context: MCPRequestContext,
        secrets: [String],
        masking: ExternalRowMasking = .byOrigin
    ) async throws -> QueryResult {
        try await context.cancellation.throwIfCancelled()
        return try await logged(
            services: services,
            approved: operation,
            principal: context.principal,
            client: MCPAuditLogger.clientName(for: context.meta),
            secrets: secrets,
            source: historySource(for: context)
        ) {
            let outcome = try await services.connectionBridge.runStatement(
                operation,
                maxRows: maxRows,
                timeoutSeconds: timeoutSeconds,
                cancellation: context.cancellation,
                masking: masking
            )
            return (outcome.result, outcome.result.rows.count)
        }
    }

    private static func logged<Output>(
        services: MCPToolServices,
        approved: ApprovedOperation,
        principal: MCPPrincipal,
        client: String?,
        secrets: [String],
        source: QueryHistorySource,
        operation: () async throws -> (Output, Int)
    ) async throws -> Output {
        let scope = approved.scope
        let query = approved.statements.map(\.sql).joined(separator: "\n")
        let connectionId = scope.connectionId
        let databaseName = scope.database
        let startTime = Date()
        let operationStart = ContinuousClock.Instant.now
        do {
            let (result, rowCount) = try await operation()
            let elapsed = Date().timeIntervalSince(startTime)
            await services.authPolicy.logQuery(
                sql: query,
                connectionId: connectionId,
                databaseName: scope.database,
                executionTime: elapsed,
                rowCount: rowCount,
                wasSuccessful: true,
                errorMessage: nil,
                source: source
            )
            await reportMcpQueryFinished(
                .succeeded(OperationSummary(rowsReturned: rowCount)),
                connectionId: connectionId,
                databaseName: databaseName,
                startedAt: operationStart
            )
            MCPAuditLogger.logQueryExecuted(
                principal: principal,
                client: client,
                connectionId: connectionId,
                sql: query,
                durationMs: Int(elapsed * 1_000),
                rowCount: rowCount,
                outcome: .success
            )
            return result
        } catch let error as CancellationError {
            throw error
        } catch {
            let elapsed = Date().timeIntervalSince(startTime)
            let redacted = MCPErrorRedactor.message(for: error, secrets: secrets)
            await services.authPolicy.logQuery(
                sql: query,
                connectionId: connectionId,
                databaseName: scope.database,
                executionTime: elapsed,
                rowCount: 0,
                wasSuccessful: false,
                errorMessage: redacted,
                source: source
            )
            MCPAuditLogger.logQueryExecuted(
                principal: principal,
                client: client,
                connectionId: connectionId,
                sql: query,
                durationMs: Int(elapsed * 1_000),
                rowCount: 0,
                outcome: .error,
                errorMessage: redacted
            )
            await reportMcpQueryFinished(
                .failed(reason: redacted),
                connectionId: connectionId,
                databaseName: databaseName,
                startedAt: operationStart
            )
            throw translate(error, secrets: secrets)
        }
    }

    // The call's payload, and the rows it returned across every result set, which the history and audit log record.
    private static func run(
        _ operation: ApprovedOperation,
        services: MCPToolServices,
        maxRows: Int,
        timeoutSeconds: Int,
        cancellation: MCPCancellationToken?,
        masking: ExternalRowMasking
    ) async throws -> (payload: JsonValue, rowsReturned: Int) {
        switch operation.unit {
        case .statement:
            let payload = try await services.connectionBridge.executeQuery(
                operation,
                maxRows: maxRows,
                timeoutSeconds: timeoutSeconds,
                cancellation: cancellation,
                masking: masking
            )
            return (payload, payload["row_count"]?.intValue ?? 0)
        case .script:
            return try await services.connectionBridge.executeScript(
                operation,
                maxRows: maxRows,
                timeoutSeconds: timeoutSeconds,
                cancellation: cancellation
            )
        }
    }

    static func translate(_ error: Error, secrets: [String]) -> Error {
        if let dataError = error as? DatabaseAccessError {
            return MCPToolExecutionError.from(dataError, secrets: secrets)
        }
        if let toolError = error as? MCPToolExecutionError {
            return toolError
        }
        if let protocolError = error as? MCPProtocolError {
            return protocolError
        }
        if error is CancellationError {
            return error
        }
        return MCPToolExecutionError.queryFailed(MCPErrorRedactor.message(for: error, secrets: secrets))
    }

    // An MCP query has no tab, so its notification brings the connection's most recent window forward.
    @MainActor
    private static func reportMcpQueryFinished(
        _ outcome: OperationOutcome,
        connectionId: UUID,
        databaseName: String?,
        startedAt: ContinuousClock.Instant
    ) {
        guard let connection = ConnectionStorage.shared.loadConnections().first(where: { $0.id == connectionId })
        else { return }
        OperationCompletionReporter.shared.report(
            OperationCompletion(
                kind: .mcpQuery,
                owner: .connection(connectionId),
                connectionId: connectionId,
                connectionName: connection.name,
                databaseName: databaseName,
                elapsed: startedAt.duration(to: .now),
                outcome: outcome
            )
        )
    }
}
