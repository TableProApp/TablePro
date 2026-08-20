import Foundation

struct MCPPromptTarget: Sendable {
    let connection: MCPConnectionDescriptor
    let scope: DatabaseScope
    let serverVersion: String?

    var scopeDescription: String {
        scope.qualifiedDescription.isEmpty ? connection.name : scope.qualifiedDescription
    }
}

struct MCPPromptTableEntry: Sendable, Equatable {
    let name: String
    let type: String
    let rowCount: Int?
}

struct MCPPromptColumn: Sendable, Equatable {
    let name: String
    let dataType: String
    let isNullable: Bool
    let isPrimaryKey: Bool
    let defaultValue: String?
    let comment: String?
}

struct MCPPromptIndex: Sendable, Equatable {
    let name: String
    let columns: [String]
    let isUnique: Bool
    let isPrimary: Bool
}

struct MCPPromptForeignKey: Sendable, Equatable {
    let column: String
    let referencedTable: String
    let referencedColumn: String
}

struct MCPPromptTableDetail: Sendable, Equatable {
    let name: String
    let columns: [MCPPromptColumn]
    let indexes: [MCPPromptIndex]
    let foreignKeys: [MCPPromptForeignKey]
    let ddl: String?
    let approximateRowCount: Int?
}

struct MCPPromptHistoryEntry: Sendable, Equatable {
    let query: String
    let databaseName: String
    let statementType: String
    let source: String
    let executedAt: String
    let executionTimeMilliseconds: Double
    let rowCount: Int
    let wasSuccessful: Bool
    let errorMessage: String?
}

struct MCPPromptSchemaReader: Sendable {
    static let historyPeriods = ["today", "this_week", "this_month", "all"]

    private let services: MCPToolServices
    private let source: any MCPCompletionSchemaSource

    init(services: MCPToolServices) {
        self.init(services: services, source: MCPBridgeCompletionSchemaSource(services: services))
    }

    init(services: MCPToolServices, source: any MCPCompletionSchemaSource) {
        self.services = services
        self.source = source
    }

    func target(
        reference: String,
        database: String?,
        schema: String?,
        principal: MCPPrincipal
    ) async throws -> MCPPromptTarget {
        let connection = try await resolveConnection(reference: reference, principal: principal)
        try await authorize(connectionId: connection.id, principal: principal)
        do {
            let scope = try await services.connectionBridge.resolveScope(
                connectionId: connection.id,
                database: database,
                schema: schema
            )
            return MCPPromptTarget(
                connection: connection,
                scope: scope,
                serverVersion: await serverVersion(connectionId: connection.id)
            )
        } catch {
            throw Self.mapped(error)
        }
    }

    func tableInventory(target: MCPPromptTarget, includeRowCounts: Bool) async throws -> [MCPPromptTableEntry] {
        do {
            let payload = try await services.connectionBridge.listTables(
                scope: target.scope,
                includeRowCounts: includeRowCounts
            )
            return (payload["tables"]?.arrayValue ?? []).compactMap { entry in
                guard let name = entry["name"]?.stringValue else { return nil }
                return MCPPromptTableEntry(
                    name: name,
                    type: entry["type"]?.stringValue ?? "TABLE",
                    rowCount: entry["row_count"]?.intValue
                )
            }
        } catch {
            throw Self.mapped(error)
        }
    }

    func tableDetail(target: MCPPromptTarget, table: String) async throws -> MCPPromptTableDetail {
        do {
            let payload = try await services.connectionBridge.describeTable(scope: target.scope, table: table)
            return Self.decodeTableDetail(name: table, payload: payload)
        } catch {
            throw Self.mapped(error)
        }
    }

    func tableDetails(target: MCPPromptTarget, tables: [String]) async -> [MCPPromptTableDetail] {
        var details: [MCPPromptTableDetail] = []
        for table in tables {
            guard let detail = try? await tableDetail(target: target, table: table) else { continue }
            details.append(detail)
        }
        return details
    }

    func history(
        connectionId: UUID,
        limit: Int,
        period: String,
        principal: MCPPrincipal
    ) async throws -> [MCPPromptHistoryEntry] {
        try await authorize(connectionId: connectionId, principal: principal)
        do {
            let payload = try await services.connectionBridge.fetchHistoryResource(
                connectionId: connectionId,
                limit: limit,
                search: nil,
                dateFilter: Self.dateFilter(forPeriod: period)
            )
            return (payload["history"]?.arrayValue ?? []).compactMap { entry in
                guard let query = entry["query"]?.stringValue else { return nil }
                return MCPPromptHistoryEntry(
                    query: query,
                    databaseName: entry["database_name"]?.stringValue ?? "",
                    statementType: entry["statement_type"]?.stringValue ?? "",
                    source: entry["source"]?.stringValue ?? "",
                    executedAt: entry["executed_at"]?.stringValue ?? "",
                    executionTimeMilliseconds: entry["execution_time_ms"]?.doubleValue ?? 0,
                    rowCount: entry["row_count"]?.intValue ?? 0,
                    wasSuccessful: entry["was_successful"]?.boolValue ?? true,
                    errorMessage: entry["error_message"]?.stringValue
                )
            }
        } catch {
            throw Self.mapped(error)
        }
    }

    func resolveConnection(reference: String, principal: MCPPrincipal) async throws -> MCPConnectionDescriptor {
        let candidates = await source.connections(principal: principal)
        guard !candidates.isEmpty else {
            throw MCPProtocolError.invalidParams(
                detail: "This client has access to no database connection"
            )
        }
        switch MCPConnectionReferenceMatcher.resolve(reference, in: candidates) {
        case .resolved(let connection):
            return connection
        case .ambiguous(let matches):
            let ids = matches.map(\.id.uuidString).joined(separator: ", ")
            throw MCPProtocolError.invalidParams(
                detail: "Connection name '\(reference)' matches more than one connection. Use one of: \(ids)"
            )
        case .unknown:
            let names = candidates.prefix(20).map(\.name).joined(separator: ", ")
            throw MCPProtocolError.invalidParams(
                detail: "Unknown connection '\(reference)'. Available connections: \(names)"
            )
        }
    }

    private func authorize(connectionId: UUID, principal: MCPPrincipal) async throws {
        do {
            try await services.authPolicy.resolveAndAuthorize(
                principal: principal,
                tool: PromptsGetHandler.method,
                connectionId: connectionId,
                sql: nil
            )
        } catch {
            throw Self.mapped(error)
        }
    }

    private func serverVersion(connectionId: UUID) async -> String? {
        guard let status = try? await services.connectionBridge.getConnectionStatus(connectionId: connectionId) else {
            return nil
        }
        return status["server_version"]?.stringValue
    }

    private static func dateFilter(forPeriod period: String) -> String? {
        switch period {
        case "today": "today"
        case "this_week": "thisWeek"
        case "this_month": "thisMonth"
        default: nil
        }
    }

    private static func decodeTableDetail(name: String, payload: JsonValue) -> MCPPromptTableDetail {
        let columns: [MCPPromptColumn] = (payload["columns"]?.arrayValue ?? []).compactMap { entry in
            guard let columnName = entry["name"]?.stringValue else { return nil }
            return MCPPromptColumn(
                name: columnName,
                dataType: entry["data_type"]?.stringValue ?? "",
                isNullable: entry["is_nullable"]?.boolValue ?? true,
                isPrimaryKey: entry["is_primary_key"]?.boolValue ?? false,
                defaultValue: entry["default_value"]?.stringValue,
                comment: entry["comment"]?.stringValue
            )
        }
        let indexes: [MCPPromptIndex] = (payload["indexes"]?.arrayValue ?? []).compactMap { entry in
            guard let indexName = entry["name"]?.stringValue else { return nil }
            return MCPPromptIndex(
                name: indexName,
                columns: (entry["columns"]?.arrayValue ?? []).compactMap(\.stringValue),
                isUnique: entry["is_unique"]?.boolValue ?? false,
                isPrimary: entry["is_primary"]?.boolValue ?? false
            )
        }
        let foreignKeys: [MCPPromptForeignKey] = (payload["foreign_keys"]?.arrayValue ?? []).compactMap { entry in
            guard let column = entry["column"]?.stringValue,
                  let referencedTable = entry["referenced_table"]?.stringValue else { return nil }
            return MCPPromptForeignKey(
                column: column,
                referencedTable: referencedTable,
                referencedColumn: entry["referenced_column"]?.stringValue ?? ""
            )
        }
        return MCPPromptTableDetail(
            name: name,
            columns: columns,
            indexes: indexes,
            foreignKeys: foreignKeys,
            ddl: payload["ddl"]?.stringValue,
            approximateRowCount: payload["approximate_row_count"]?.intValue
        )
    }

    private static func mapped(_ error: Error) -> Error {
        guard let dataLayerError = error as? MCPDataLayerError else { return error }
        switch dataLayerError {
        case .invalidArgument(let detail):
            return MCPProtocolError.invalidParams(detail: detail)
        case .notConnected(let connectionId):
            return MCPProtocolError.invalidParams(detail: "Connection not active: \(connectionId.uuidString)")
        case .forbidden(let reason, _):
            return MCPProtocolError.forbidden(reason: reason)
        case .notFound(let detail):
            return MCPProtocolError.notFound(detail: detail)
        case .expired(let detail):
            return MCPProtocolError(code: JsonRpcErrorCode.expired, message: detail, httpStatus: .ok)
        case .timeout(let detail, _):
            return MCPProtocolError.requestTimeout(detail: detail)
        case .userCancelled:
            return MCPProtocolError.requestCancelled()
        case .dataSourceError(let detail):
            return MCPProtocolError.internalError(detail: detail)
        }
    }
}
