import Foundation

enum ToolQueryExecutor {
    static func executeAndLog(
        services: MCPToolServices,
        query: String,
        scope: DatabaseScope,
        maxRows: Int,
        timeoutSeconds: Int,
        principalLabel: String?
    ) async throws -> JsonValue {
        let connectionId = scope.connectionId
        let databaseName = scope.database
        let startTime = Date()
        let operationStart = ContinuousClock.Instant.now
        do {
            let result = try await services.connectionBridge.executeQuery(
                scope: scope,
                query: query,
                maxRows: maxRows,
                timeoutSeconds: timeoutSeconds
            )
            let elapsed = Date().timeIntervalSince(startTime)
            let rowCount = result["row_count"]?.intValue ?? 0
            await services.authPolicy.logQuery(
                sql: query,
                connectionId: connectionId,
                databaseName: databaseName,
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
                tokenId: nil,
                tokenName: principalLabel,
                connectionId: connectionId,
                sql: query,
                durationMs: Int(elapsed * 1_000),
                rowCount: rowCount,
                outcome: .success
            )
            return result
        } catch {
            let elapsed = Date().timeIntervalSince(startTime)
            await services.authPolicy.logQuery(
                sql: query,
                connectionId: connectionId,
                databaseName: databaseName,
                executionTime: elapsed,
                rowCount: 0,
                wasSuccessful: false,
                errorMessage: error.localizedDescription
            )
            MCPAuditLogger.logQueryExecuted(
                tokenId: nil,
                tokenName: principalLabel,
                connectionId: connectionId,
                sql: query,
                durationMs: Int(elapsed * 1_000),
                rowCount: 0,
                outcome: .error,
                errorMessage: error.localizedDescription
            )
            await reportMcpQueryFinished(
                .failed(reason: error.localizedDescription),
                connectionId: connectionId,
                databaseName: databaseName,
                startedAt: operationStart
            )
            throw error
        }
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
