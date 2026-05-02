import Foundation

enum ToolQueryExecutor {
    static func executeAndLog(
        services: MCPToolServices,
        query: String,
        connectionId: UUID,
        databaseName: String,
        maxRows: Int,
        timeoutSeconds: Int,
        principalLabel: String?
    ) async throws -> JsonValue {
        let startTime = Date()
        do {
            let result = try await services.connectionBridge.executeQuery(
                connectionId: connectionId,
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
            throw error
        }
    }
}
