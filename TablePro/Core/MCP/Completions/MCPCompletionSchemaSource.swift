import Foundation

public struct MCPConnectionDescriptor: Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let databaseType: String
    public let database: String
    public let isConnected: Bool
    public let safeMode: String

    public init(
        id: UUID,
        name: String,
        databaseType: String,
        database: String,
        isConnected: Bool,
        safeMode: String
    ) {
        self.id = id
        self.name = name
        self.databaseType = databaseType
        self.database = database
        self.isConnected = isConnected
        self.safeMode = safeMode
    }
}

public enum MCPConnectionReferenceMatch: Sendable, Equatable {
    case resolved(MCPConnectionDescriptor)
    case ambiguous([MCPConnectionDescriptor])
    case unknown
}

public enum MCPConnectionReferenceMatcher {
    public static func resolve(
        _ reference: String,
        in connections: [MCPConnectionDescriptor]
    ) -> MCPConnectionReferenceMatch {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unknown }

        if let uuid = UUID(uuidString: trimmed) {
            guard let match = connections.first(where: { $0.id == uuid }) else { return .unknown }
            return .resolved(match)
        }

        let named = connections.filter { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        if named.count > 1 { return .ambiguous(named) }
        guard let match = named.first else { return .unknown }
        return .resolved(match)
    }
}

public protocol MCPCompletionSchemaSource: Sendable {
    func connections(principal: MCPPrincipal) async -> [MCPConnectionDescriptor]
    func databases(connectionId: UUID) async -> [String]
    func schemas(connectionId: UUID, database: String?) async -> [String]
    func tables(connectionId: UUID, database: String?, schema: String?) async -> [String]
}

public struct MCPBridgeCompletionSchemaSource: MCPCompletionSchemaSource {
    private let services: MCPToolServices

    public init(services: MCPToolServices) {
        self.services = services
    }

    public func connections(principal: MCPPrincipal) async -> [MCPConnectionDescriptor] {
        let payload = await services.connectionBridge.listConnections(principal: principal)
        return (payload["connections"]?.arrayValue ?? []).compactMap { entry in
            guard let rawId = entry["id"]?.stringValue, let id = UUID(uuidString: rawId) else { return nil }
            guard principal.connectionAccess.allows(id) else { return nil }
            return MCPConnectionDescriptor(
                id: id,
                name: entry["name"]?.stringValue ?? rawId,
                databaseType: entry["type"]?.stringValue ?? "",
                database: entry["database"]?.stringValue ?? "",
                isConnected: entry["is_connected"]?.boolValue ?? false,
                safeMode: entry["safe_mode"]?.stringValue ?? "off"
            )
        }
    }

    public func databases(connectionId: UUID) async -> [String] {
        guard await isConnected(connectionId) else { return [] }
        guard let payload = try? await services.connectionBridge.listDatabases(connectionId: connectionId) else {
            return []
        }
        return (payload["databases"]?.arrayValue ?? []).compactMap(\.stringValue)
    }

    public func schemas(connectionId: UUID, database: String?) async -> [String] {
        guard let scope = await resolvedScope(connectionId: connectionId, database: database, schema: nil) else {
            return []
        }
        guard let payload = try? await services.connectionBridge.listSchemas(scope: scope) else { return [] }
        return (payload["schemas"]?.arrayValue ?? []).compactMap(\.stringValue)
    }

    public func tables(connectionId: UUID, database: String?, schema: String?) async -> [String] {
        guard let scope = await resolvedScope(connectionId: connectionId, database: database, schema: schema) else {
            return []
        }
        guard let payload = try? await services.connectionBridge.listTables(scope: scope, includeRowCounts: false)
        else {
            return []
        }
        return (payload["tables"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
    }

    private func resolvedScope(connectionId: UUID, database: String?, schema: String?) async -> DatabaseScope? {
        guard await isConnected(connectionId) else { return nil }
        return try? await services.connectionBridge.resolveScope(
            connectionId: connectionId,
            database: database,
            schema: schema
        )
    }

    private func isConnected(_ connectionId: UUID) async -> Bool {
        guard let status = try? await services.connectionBridge.getConnectionStatus(connectionId: connectionId) else {
            return false
        }
        return status["status"]?.stringValue == "connected"
    }
}
