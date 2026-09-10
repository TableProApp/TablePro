import Foundation
import os

public struct ResourcesReadHandler: MCPMethodHandler {
    public static let method = "resources/read"
    public static let requiredScopes: Set<MCPScope> = [.resourcesRead]

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Resources")

    private let services: MCPToolServices

    public init(services: MCPToolServices) {
        self.services = services
    }

    public func handle(params: JsonValue?, context: MCPRequestContext) async throws -> MCPResult {
        guard case .string(let uri)? = params?["uri"] else {
            throw MCPProtocolError.invalidParams(detail: "Missing required parameter: uri")
        }

        do {
            let route = try ResourcesUriRoute.parse(uri: uri)
            try await context.throwIfCancelled()
            let payload = try await Self.read(route: route, context: context, services: services)

            Self.logger.debug("resources/read uri=\(uri, privacy: .public)")
            MCPAuditLogger.logResourceRead(
                principal: context.principal,
                uri: uri,
                outcome: .success
            )

            return .complete(
                ["contents": .array([Self.content(uri: uri, payload: payload)])],
                cacheHint: .privateFor(seconds: route.cacheTtlSeconds)
            )
        } catch {
            MCPAuditLogger.logResourceRead(
                principal: context.principal,
                uri: uri,
                outcome: .error,
                errorMessage: (error as? MCPProtocolError)?.message ?? error.localizedDescription
            )
            throw error
        }
    }

    private static func read(
        route: ResourcesUriRoute,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> JsonValue {
        do {
            if let connectionId = route.connectionId {
                try await services.authPolicy.resolveAndAuthorize(
                    principal: context.principal,
                    tool: method,
                    connectionId: connectionId,
                    sql: nil
                )
            }
            return try await payload(for: route, principal: context.principal, services: services)
        } catch let error as DatabaseAccessError {
            throw mapDomainError(error)
        }
    }

    private static func payload(
        for route: ResourcesUriRoute,
        principal: MCPPrincipal,
        services: MCPToolServices
    ) async throws -> JsonValue {
        let bridge = services.connectionBridge
        switch route {
        case .connections:
            return await bridge.listConnections(principal: principal)

        case .connectionSchema(let connectionId):
            return try await bridge.fetchSchemaResource(connectionId: connectionId)

        case .connectionHistory(let connectionId, let limit, let search, let dateFilter):
            return try await bridge.fetchHistoryResource(
                connectionId: connectionId,
                limit: limit,
                search: search,
                dateFilter: dateFilter
            )

        case .connectionDatabases(let connectionId):
            return try await bridge.listDatabases(connectionId: connectionId)

        case .connectionSchemas(let connectionId, let database):
            let scope = try await bridge.resolveScope(connectionId: connectionId, database: database, schema: nil)
            return try await bridge.listSchemas(scope: scope)

        case .connectionTables(let connectionId, let database, let schema, let includeRowCounts):
            let scope = try await bridge.resolveScope(connectionId: connectionId, database: database, schema: schema)
            return try await bridge.listTables(scope: scope, includeRowCounts: includeRowCounts)

        case .tableDescription(let connectionId, let database, let schema, let table):
            let scope = try await bridge.resolveScope(connectionId: connectionId, database: database, schema: schema)
            return try await bridge.describeTable(scope: scope, table: table)

        case .tableDefinition(let connectionId, let database, let schema, let table):
            let scope = try await bridge.resolveScope(connectionId: connectionId, database: database, schema: schema)
            return try await bridge.getTableDDL(scope: scope, table: table)
        }
    }

    private static func content(uri: String, payload: JsonValue) -> JsonValue {
        .object([
            "uri": .string(uri),
            "mimeType": .string(ResourcesUriRoute.mimeType),
            "text": .string(encodeJsonString(payload))
        ])
    }

    private static func mapDomainError(_ error: DatabaseAccessError) -> MCPProtocolError {
        switch error {
        case .invalidArgument(let detail):
            return .invalidParams(detail: detail)
        case .notConnected(let id):
            return .invalidParams(detail: "Connection not active: \(id.uuidString)")
        case .forbidden(let reason, _):
            return .forbidden(reason: reason)
        case .notFound(let detail):
            return .notFound(detail: detail)
        case .expired(let detail):
            return MCPProtocolError(code: JsonRpcErrorCode.expired, message: detail, httpStatus: .ok)
        case .timeout(let detail, _):
            return .requestTimeout(detail: detail)
        case .userCancelled:
            return .requestCancelled()
        case .dataSourceError(let detail):
            return .internalError(detail: detail)
        }
    }

    private static func encodeJsonString(_ value: JsonValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}
