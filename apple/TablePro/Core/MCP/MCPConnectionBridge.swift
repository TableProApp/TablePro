import Foundation
import os
import TableProMCP
import TableProPluginKit

/// The MCP wire encoding over `DatabaseAccessBridge`.
///
/// Connecting, switching container and running a statement live one layer down, where every
/// programmatic caller reaches them. What is left here is the part that is genuinely MCP's: turning
/// those results into the `JsonValue` shapes the tools and resources are specified in.
public actor MCPConnectionBridge {
    static let logger = Logger(subsystem: "com.TablePro", category: "MCPConnectionBridge")

    private let access = DatabaseAccessBridge()

    public init() {}

    func listConnections(principal: MCPPrincipal, purpose: MCPConnectionListPurpose = .agent) async -> JsonValue {
        await listConnections(access: principal.connectionAccess, purpose: purpose)
    }

    private func listConnections(access: ConnectionAccess, purpose: MCPConnectionListPurpose) async -> JsonValue {
        let listings = await MainActor.run { ExternalConnectionDirectory.listings() }
        return MCPConnectionListEncoder.encode(listings, access: access, purpose: purpose)
    }

    func connect(connectionId: UUID) async throws -> JsonValue {
        let snapshot = try await access.connect(connectionId: connectionId)

        var result: [String: JsonValue] = [
            "status": .string("connected"),
            "connection_id": .string(connectionId.uuidString),
            "current_database": .string(snapshot.database)
        ]
        if let version = snapshot.serverVersion {
            result["server_version"] = .string(version)
        }
        if let schema = snapshot.schema {
            result["current_schema"] = .string(schema)
        }
        return .object(result)
    }

    func disconnect(connectionId: UUID) async throws -> JsonValue {
        try await access.disconnect(connectionId: connectionId)
        return .object([
            "status": .string("disconnected"),
            "connection_id": .string(connectionId.uuidString)
        ])
    }

    func getConnectionStatus(connectionId: UUID) async throws -> JsonValue {
        let snapshot = try await access.connectionStatus(connectionId: connectionId)

        let statusString: String
        var errorDetail: JsonValue?
        switch snapshot.status {
        case .connected: statusString = "connected"
        case .connecting: statusString = "connecting"
        case .disconnected: statusString = "disconnected"
        case .error(let message):
            statusString = "error"
            errorDetail = .string(MCPErrorRedactor.redact(message))
        }

        var result: [String: JsonValue] = [
            "status": .string(statusString),
            "connection_id": .string(connectionId.uuidString),
            "current_database": .string(snapshot.database),
            "connected_at": .string(Self.iso8601.withLockUnchecked { $0.string(from: snapshot.connectedAt) }),
            "last_active_at": .string(Self.iso8601.withLockUnchecked { $0.string(from: snapshot.lastActiveAt) })
        ]
        if let schema = snapshot.schema {
            result["current_schema"] = .string(schema)
        }
        if let version = snapshot.serverVersion {
            result["server_version"] = .string(version)
        }
        if let errorDetail {
            result["error"] = errorDetail
        }
        return .object(result)
    }

    func maskingPolicy(for connectionId: UUID) async -> MaskingPolicy {
        await access.maskingPolicy(for: connectionId)
    }

    func resolveScope(connectionId: UUID, database: String?, schema: String?) async throws -> DatabaseScope {
        try await access.resolveScope(connectionId: connectionId, database: database, schema: schema)
    }

    func switchDatabase(connectionId: UUID, database: String) async throws -> JsonValue {
        try await access.switchDatabase(connectionId: connectionId, database: database)
        return .object([
            "status": .string("switched"),
            "connection_id": .string(connectionId.uuidString),
            "current_database": .string(database)
        ])
    }

    func switchSchema(connectionId: UUID, schema: String) async throws -> JsonValue {
        try await access.switchSchema(connectionId: connectionId, schema: schema)
        return .object([
            "status": .string("switched"),
            "connection_id": .string(connectionId.uuidString),
            "current_schema": .string(schema)
        ])
    }

    func plannedStatement(scope: DatabaseScope, query: String, maxRows: Int) async throws -> OperationStatement {
        try await access.plannedStatement(scope: scope, query: query, maxRows: maxRows)
    }

    func plannedScript(scope: DatabaseScope, query: String, maxRows: Int) async throws -> DatabaseAccessBridge.PlannedText {
        try await access.plannedScript(scope: scope, query: query, maxRows: maxRows)
    }

    func executeQuery(
        _ operation: ApprovedOperation,
        maxRows: Int,
        timeoutSeconds: Int,
        cancellation: MCPCancellationToken?,
        masking: ExternalRowMasking = .byOrigin,
        budget: ExternalAnswerBudget = .mcpAnswer
    ) async throws -> JsonValue {
        let outcome = try await runStatement(
            operation,
            maxRows: maxRows,
            timeoutSeconds: timeoutSeconds,
            cancellation: cancellation,
            masking: masking,
            budget: budget
        )
        return Self.encode(
            result: outcome.result,
            scope: operation.scope,
            executionTimeMs: outcome.executionTimeMs,
            notes: outcome.budget?.notes ?? []
        )
    }

    func executeScript(
        _ operation: ApprovedOperation,
        maxRows: Int,
        timeoutSeconds: Int,
        cancellation: MCPCancellationToken?,
        budget: ExternalAnswerBudget = .mcpAnswer
    ) async throws -> (payload: JsonValue, rowsReturned: Int) {
        let outcome = try await access.runScript(
            operation,
            maxRows: maxRows,
            timeoutSeconds: timeoutSeconds,
            cancellation: cancellation,
            budget: budget
        )
        return (Self.encode(script: outcome, scope: operation.scope), outcome.rowsReturned)
    }

    // A nil budget sends the rows whole, for a caller that holds them to a budget of its own.
    func runStatement(
        _ operation: ApprovedOperation,
        maxRows: Int,
        timeoutSeconds: Int,
        cancellation: MCPCancellationToken?,
        masking: ExternalRowMasking = .byOrigin,
        budget: ExternalAnswerBudget? = .mcpAnswer
    ) async throws -> DatabaseAccessBridge.StatementOutcome {
        try await access.runStatement(
            operation,
            maxRows: maxRows,
            timeoutSeconds: timeoutSeconds,
            cancellation: cancellation,
            masking: masking,
            budget: budget
        )
    }

    func runExplainPlan(
        _ operation: ApprovedOperation,
        step: ExplainRequest.DriverStep,
        timeoutSeconds: Int,
        cancellation: MCPCancellationToken?,
        masking: ExternalRowMasking = .byOrigin
    ) async throws -> (result: QueryResult, executionTimeMs: Double) {
        let outcome = try await access.runExplainPlan(
            operation,
            step: step,
            timeoutSeconds: timeoutSeconds,
            cancellation: cancellation,
            masking: masking
        )
        return (outcome.result, outcome.executionTimeMs)
    }

    func countRows(
        _ operation: ApprovedOperation,
        table: String,
        filters: [TableFilter],
        logicMode: FilterLogicMode,
        exact: Bool
    ) async throws -> JsonValue {
        let outcome = try await access.countRows(
            operation, table: table, filters: filters, logicMode: logicMode, exact: exact
        )
        guard let count = outcome.count else {
            throw DatabaseAccessError.dataSourceError(
                String(localized: "This engine cannot count rows for that table.")
            )
        }
        return .object([
            "table": .string(table),
            "row_count": .int(count),
            "is_approximate": .bool(outcome.isApproximate),
            "filter_count": .int(filters.count)
        ])
    }

    func insertRows(_ operation: ApprovedOperation, table: String) async throws -> JsonValue {
        let inserted = try await access.runInserts(operation)
        return .object([
            "table": .string(table),
            "rows_submitted": .int(operation.statements.count),
            "rows_affected": .int(inserted)
        ])
    }

    func transactionControl(_ operation: ApprovedOperation, action: String) async throws -> JsonValue {
        try await access.transactionControl(operation, action: action)
        return .object([
            "status": .string(action),
            "connection_id": .string(operation.scope.connectionId.uuidString)
        ])
    }

    func createDatabase(_ operation: ApprovedOperation, name: String, options: [String: String]) async throws -> JsonValue {
        try await access.createDatabase(operation, name: name, options: options)
        return .object(["status": .string("created"), "database": .string(name)])
    }

    func dropDatabase(_ operation: ApprovedOperation, name: String) async throws -> JsonValue {
        try await access.dropDatabase(operation, name: name)
        return .object(["status": .string("dropped"), "database": .string(name)])
    }

    func dropSchema(_ operation: ApprovedOperation, name: String) async throws -> JsonValue {
        try await access.dropSchema(operation, name: name)
        return .object(["status": .string("dropped"), "schema": .string(name)])
    }

    static func encode(
        result: QueryResult,
        scope: DatabaseScope,
        executionTimeMs: Double,
        notes: [String] = []
    ) -> JsonValue {
        .object(fields(of: result, scope: scope, executionTimeMs: executionTimeMs, notes: notes))
    }

    /// A script's answer in the shape a statement's has, so a client that reads one result reads the first, plus
    /// `result_sets` with every one of them once there is more than one to read.
    static func encode(script: DatabaseAccessBridge.ScriptOutcome, scope: DatabaseScope) -> JsonValue {
        var response = fields(
            of: script.primary,
            scope: scope,
            executionTimeMs: script.executionTimeMs,
            notes: script.budget?.notes ?? []
        )
        if script.resultSets.count > 1 {
            response["result_sets"] = .array(script.resultSets.map(encode(resultSet:)))
        }
        return .object(response)
    }

    static func encode(resultSet: QueryResult) -> JsonValue {
        var entry: [String: JsonValue] = [
            "columns": .array(resultSet.columns.map { .string($0) }),
            "rows": .array(resultSet.rows.map { row in .array(row.map(cellValue)) }),
            "row_count": .int(resultSet.rows.count),
            "is_truncated": .bool(resultSet.isTruncated)
        ]
        if let statusMessage = resultSet.statusMessage {
            entry["status_message"] = .string(statusMessage)
        }
        return .object(entry)
    }

    private static func fields(
        of result: QueryResult,
        scope: DatabaseScope,
        executionTimeMs: Double,
        notes: [String]
    ) -> [String: JsonValue] {
        var response: [String: JsonValue] = [
            "columns": .array(result.columns.map { .string($0) }),
            "rows": .array(result.rows.map { row in .array(row.map(cellValue)) }),
            "row_count": .int(result.rows.count),
            "rows_affected": .int(result.rowsAffected),
            "execution_time_ms": .double(executionTimeMs),
            "is_truncated": .bool(result.isTruncated),
            "database": .string(scope.database)
        ]
        if let schema = scope.schema {
            response["schema"] = .string(schema)
        }
        if let statusMessage = result.statusMessage {
            response["status_message"] = .string(statusMessage)
        }
        if !notes.isEmpty {
            response["notes"] = .array(notes.map(JsonValue.string))
        }
        return response
    }

    static func cellValue(_ cell: PluginCellValue) -> JsonValue {
        switch cell {
        case .null: return .null
        case .text(let value): return .string(value)
        case .bytes(let data): return .string(data.base64EncodedString())
        }
    }

    static let iso8601 = OSAllocatedUnfairLock(uncheckedState: ISO8601DateFormatter())

    // For metadata only: listing databases, the create-database form, quoting names. Statements go through `access`.
    func resolveDriver(_ connectionId: UUID) async throws -> (DatabaseDriver, DatabaseType) {
        try await access.resolveDriver(connectionId)
    }

    @discardableResult
    func ensureConnected(_ connectionId: UUID) async throws -> DatabaseType {
        try await access.ensureConnected(connectionId)
    }

    func resolveConnection(_ connectionId: UUID) async throws -> DatabaseConnection {
        try await access.resolveConnection(connectionId)
    }

    static func statementText(_ query: String, databaseType: DatabaseType) -> String {
        DatabaseAccessBridge.statementText(query, databaseType: databaseType)
    }
}

extension MCPCancellationToken: StatementCancellationSignal {
    func onCancelRequested(_ handler: @escaping @Sendable () async -> Void) async {
        await onCancel { _ in await handler() }
    }
}
