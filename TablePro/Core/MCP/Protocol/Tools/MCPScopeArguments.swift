import Foundation

enum MCPScopeArguments {
    static let keys: Set<String> = ["connection_id", "database", "schema"]

    static func resolve(
        _ arguments: JsonValue,
        services: MCPToolServices
    ) async throws -> DatabaseScope {
        let connectionId = try MCPArgumentDecoder.requireUuid(arguments, key: "connection_id")
        return try await resolve(arguments, connectionId: connectionId, services: services)
    }

    static func resolve(
        _ arguments: JsonValue,
        connectionId: UUID,
        services: MCPToolServices
    ) async throws -> DatabaseScope {
        let database = try MCPArgumentDecoder.optionalString(arguments, key: "database")
        let schema = try MCPArgumentDecoder.optionalString(arguments, key: "schema")
        return try await services.connectionBridge.resolveScope(
            connectionId: connectionId,
            database: database,
            schema: schema
        )
    }
}
