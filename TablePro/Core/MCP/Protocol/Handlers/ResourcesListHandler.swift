import Foundation
import os

public struct ResourcesListHandler: MCPMethodHandler {
    public static let method = "resources/list"
    public static let requiredScopes: Set<MCPScope> = [.resourcesRead]
    public static let allowedSessionStates: Set<MCPSessionAllowedState> = [.ready]

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Resources")

    private let services: MCPToolServices

    public init(services: MCPToolServices) {
        self.services = services
    }

    public func handle(params: JsonValue?, context: MCPRequestContext) async throws -> JsonRpcMessage {
        var resources: [JsonValue] = []
        resources.append(Self.staticConnectionsResource())

        let connectedItems = await Self.connectedConnectionItems(services: services)
        for item in connectedItems {
            resources.append(Self.schemaResource(for: item))
            resources.append(Self.historyResource(for: item))
        }

        let result: JsonValue = .object(["resources": .array(resources)])
        Self.logger.debug("resources/list returned \(resources.count, privacy: .public) entries")
        return MCPMethodHandlerHelpers.successResponse(id: context.requestId, result: result)
    }

    private static func staticConnectionsResource() -> JsonValue {
        .object([
            "uri": .string("tablepro://connections"),
            "name": .string(String(localized: "Saved Connections")),
            "description": .string(String(localized: "List of all saved database connections with metadata")),
            "mimeType": .string("application/json")
        ])
    }

    private struct ConnectedConnectionItem: Sendable {
        let id: String
        let name: String
    }

    private static func connectedConnectionItems(services: MCPToolServices) async -> [ConnectedConnectionItem] {
        let value = await services.connectionBridge.listConnections()
        guard let connections = value["connections"]?.arrayValue else { return [] }

        return connections.compactMap { entry -> ConnectedConnectionItem? in
            guard let id = entry["id"]?.stringValue else { return nil }
            guard entry["is_connected"]?.boolValue == true else { return nil }
            let name = entry["name"]?.stringValue ?? id
            return ConnectedConnectionItem(id: id, name: name)
        }
    }

    private static func schemaResource(for item: ConnectedConnectionItem) -> JsonValue {
        .object([
            "uri": .string("tablepro://connections/\(item.id)/schema"),
            "name": .string(String(format: String(localized: "Schema for %@"), item.name)),
            "description": .string(String(localized: "Tables, columns, indexes, and foreign keys for the connected database")),
            "mimeType": .string("application/json")
        ])
    }

    private static func historyResource(for item: ConnectedConnectionItem) -> JsonValue {
        .object([
            "uri": .string("tablepro://connections/\(item.id)/history"),
            "name": .string(String(format: String(localized: "Query history for %@"), item.name)),
            "description": .string(String(localized: "Recent query history for this connection")),
            "mimeType": .string("application/json")
        ])
    }
}
