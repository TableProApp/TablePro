import Foundation
import os

public actor MCPCompletionProvider {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Completion")
    public static let defaultCacheDuration: TimeInterval = 15
    private static let connectionContextKeys = ["connection", "connection_id", "id"]

    private struct CacheKey: Hashable, Sendable {
        let principal: String
        let kind: String
        let connectionId: UUID
        let database: String?
        let schema: String?
    }

    private struct Expiring<Value: Sendable>: Sendable {
        let value: Value
        let expiresAt: Date
    }

    private let source: any MCPCompletionSchemaSource
    private let clock: any MCPClock
    private let cacheDuration: TimeInterval
    private var nameCache: [CacheKey: Expiring<[String]>] = [:]
    private var connectionCache: [String: Expiring<[MCPConnectionDescriptor]>] = [:]

    public init(services: MCPToolServices) {
        self.init(source: MCPBridgeCompletionSchemaSource(services: services))
    }

    public init(
        source: any MCPCompletionSchemaSource,
        clock: any MCPClock = MCPSystemClock(),
        cacheDuration: TimeInterval = MCPCompletionProvider.defaultCacheDuration
    ) {
        self.source = source
        self.clock = clock
        self.cacheDuration = cacheDuration
    }

    public func complete(
        reference: MCPCompletionReference,
        argumentName: String,
        argumentValue: String,
        context: [String: String],
        principal: MCPPrincipal
    ) async -> MCPCompletionResult {
        guard let target = MCPCompletionTarget.resolve(reference: reference, argumentName: argumentName) else {
            return .empty
        }
        let resolvedContext = Self.contextMerged(with: reference, context: context)
        let candidates = await candidates(for: target, context: resolvedContext, principal: principal)
        var result = MCPCompletionResult.matching(
            candidates,
            prefix: argumentValue,
            preservingOrder: target.hasDeclaredOrder
        )
        if result.values.isEmpty, !argumentValue.isEmpty, target == .connection {
            let identifiers = await connections(principal: principal).map(\.id.uuidString)
            result = MCPCompletionResult.matching(identifiers, prefix: argumentValue)
        }
        Self.logger.debug(
            """
            completion ref=\(reference.describedReference, privacy: .public) \
            argument=\(argumentName, privacy: .public) \
            values=\(result.values.count, privacy: .public) total=\(result.total, privacy: .public)
            """
        )
        return result
    }

    public func invalidate() {
        nameCache.removeAll()
        connectionCache.removeAll()
    }

    private func candidates(
        for target: MCPCompletionTarget,
        context: [String: String],
        principal: MCPPrincipal
    ) async -> [String] {
        switch target {
        case .values(let values):
            return values
        case .connection:
            return await connectionNames(principal: principal)
        case .connectionId:
            return await connections(principal: principal).map(\.id.uuidString)
        case .database:
            guard let connection = await contextConnection(context: context, principal: principal) else { return [] }
            return await cachedNames(principal: principal, kind: "databases", connectionId: connection.id) {
                await self.source.databases(connectionId: connection.id)
            }
        case .schema:
            guard let connection = await contextConnection(context: context, principal: principal) else { return [] }
            let database = context["database"]
            return await cachedNames(
                principal: principal,
                kind: "schemas",
                connectionId: connection.id,
                database: database
            ) {
                await self.source.schemas(connectionId: connection.id, database: database)
            }
        case .table:
            guard let connection = await contextConnection(context: context, principal: principal) else { return [] }
            let database = context["database"]
            let schema = context["schema"]
            return await cachedNames(
                principal: principal,
                kind: "tables",
                connectionId: connection.id,
                database: database,
                schema: schema
            ) {
                await self.source.tables(connectionId: connection.id, database: database, schema: schema)
            }
        }
    }

    private func connectionNames(principal: MCPPrincipal) async -> [String] {
        let connections = await connections(principal: principal)
        var occurrences: [String: Int] = [:]
        for connection in connections {
            occurrences[connection.name.lowercased(), default: 0] += 1
        }
        return connections.map { connection in
            let isDistinct = occurrences[connection.name.lowercased()] == 1 && !connection.name.isEmpty
            return isDistinct ? connection.name : connection.id.uuidString
        }
    }

    private func connections(principal: MCPPrincipal) async -> [MCPConnectionDescriptor] {
        let now = await clock.now()
        pruneExpired(now: now)
        if let cached = connectionCache[principal.tokenFingerprint], cached.expiresAt > now {
            return cached.value
        }
        let connections = await source.connections(principal: principal)
        connectionCache[principal.tokenFingerprint] = Expiring(
            value: connections,
            expiresAt: now.addingTimeInterval(cacheDuration)
        )
        return connections
    }

    private func contextConnection(
        context: [String: String],
        principal: MCPPrincipal
    ) async -> MCPConnectionDescriptor? {
        guard let reference = Self.connectionContextKeys.compactMap({ context[$0] }).first(where: { !$0.isEmpty })
        else {
            return nil
        }
        let connections = await connections(principal: principal)
        guard case .resolved(let connection) = MCPConnectionReferenceMatcher.resolve(reference, in: connections) else {
            return nil
        }
        return connection
    }

    private func cachedNames(
        principal: MCPPrincipal,
        kind: String,
        connectionId: UUID,
        database: String? = nil,
        schema: String? = nil,
        load: () async -> [String]
    ) async -> [String] {
        let key = CacheKey(
            principal: principal.tokenFingerprint,
            kind: kind,
            connectionId: connectionId,
            database: database,
            schema: schema
        )
        let now = await clock.now()
        pruneExpired(now: now)
        if let cached = nameCache[key], cached.expiresAt > now {
            return cached.value
        }
        let values = await load()
        nameCache[key] = Expiring(value: values, expiresAt: now.addingTimeInterval(cacheDuration))
        return values
    }

    private static func contextMerged(
        with reference: MCPCompletionReference,
        context: [String: String]
    ) -> [String: String] {
        guard case .resourceTemplate(let uri) = reference,
              let route = try? ResourcesUriRoute.parse(uri: uri) else {
            return context
        }
        var merged = context
        if let connectionId = route.connectionId, connectionContextKeys.allSatisfy({ merged[$0] == nil }) {
            merged["connection_id"] = connectionId.uuidString
        }
        let scope = Self.routeScope(route)
        if let database = scope.database, merged["database"] == nil {
            merged["database"] = database
        }
        if let schema = scope.schema, merged["schema"] == nil {
            merged["schema"] = schema
        }
        return merged
    }

    private static func routeScope(_ route: ResourcesUriRoute) -> (database: String?, schema: String?) {
        switch route {
        case .connectionSchemas(_, let database):
            return (database, nil)
        case .connectionTables(_, let database, let schema, _):
            return (database, schema)
        case .tableDescription(_, let database, let schema, _),
             .tableDefinition(_, let database, let schema, _):
            return (database, schema)
        default:
            return (nil, nil)
        }
    }

    private func pruneExpired(now: Date) {
        nameCache = nameCache.filter { $0.value.expiresAt > now }
        connectionCache = connectionCache.filter { $0.value.expiresAt > now }
    }
}
