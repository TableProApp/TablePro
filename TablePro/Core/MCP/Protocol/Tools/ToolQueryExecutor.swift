import Foundation

enum ToolQueryExecutor {
    /// What one call sends: a statement, or a text that runs as a script where the engine takes one, whose every
    /// result set comes back.
    enum Unit: Sendable {
        case statement
        case script
    }

    static func executeAndLog(
        services: MCPToolServices,
        query: String,
        scope: DatabaseScope,
        maxRows: Int,
        timeoutSeconds: Int,
        context: MCPRequestContext,
        secrets: [String],
        unit: Unit = .statement
    ) async throws -> JsonValue {
        try await context.cancellation.throwIfCancelled()
        return try await executeAndLog(
            services: services,
            query: query,
            scope: scope,
            maxRows: maxRows,
            timeoutSeconds: timeoutSeconds,
            principal: context.principal,
            cancellation: context.cancellation,
            secrets: secrets,
            unit: unit
        )
    }

    static func executeAndLog(
        services: MCPToolServices,
        query: String,
        scope: DatabaseScope,
        maxRows: Int,
        timeoutSeconds: Int,
        principal: MCPPrincipal,
        cancellation: MCPCancellationToken? = nil,
        secrets: [String] = [],
        unit: Unit = .statement
    ) async throws -> JsonValue {
        let connectionId = scope.connectionId
        let databaseName = scope.database
        let startTime = Date()
        let operationStart = ContinuousClock.Instant.now
        do {
            let (result, rowCount) = try await run(
                unit,
                services: services,
                query: query,
                scope: scope,
                maxRows: maxRows,
                timeoutSeconds: timeoutSeconds,
                cancellation: cancellation
            )
            let elapsed = Date().timeIntervalSince(startTime)
            await services.authPolicy.logQuery(
                sql: query,
                connectionId: connectionId,
                databaseName: scope.database,
                executionTime: elapsed,
                rowCount: rowCount,
                wasSuccessful: true,
                errorMessage: nil
            )
            await reportMcpQueryFinished(
                .succeeded(OperationSummary(rowsReturned: rowCount)),
                connectionId: connectionId,
                databaseName: databaseName,
                startedAt: operationStart
            )
            MCPAuditLogger.logQueryExecuted(
                principal: principal,
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
                errorMessage: redacted
            )
            MCPAuditLogger.logQueryExecuted(
                principal: principal,
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

    /// The call's payload, and the rows it returned across every result set, which the history and the audit log
    /// record.
    private static func run(
        _ unit: Unit,
        services: MCPToolServices,
        query: String,
        scope: DatabaseScope,
        maxRows: Int,
        timeoutSeconds: Int,
        cancellation: MCPCancellationToken?
    ) async throws -> (payload: JsonValue, rowsReturned: Int) {
        switch unit {
        case .statement:
            let payload = try await services.connectionBridge.executeQuery(
                scope: scope,
                query: query,
                maxRows: maxRows,
                timeoutSeconds: timeoutSeconds,
                cancellation: cancellation
            )
            return (payload, payload["row_count"]?.intValue ?? 0)
        case .script:
            return try await services.connectionBridge.executeScript(
                scope: scope,
                query: query,
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

    /// An MCP query has no tab and no window of its own, so its completion is owned by the
    /// connection. Clicking the notification brings the connection's most recent window forward
    /// rather than focusing a tab that never existed.
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
