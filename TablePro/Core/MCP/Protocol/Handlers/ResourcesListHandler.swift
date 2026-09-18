import Foundation
import os

public struct ResourcesListHandler: MCPMethodHandler {
    public static let method = "resources/list"
    public static let requiredScopes: Set<MCPScope> = [.resourcesRead]

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Resources")
    private static let cacheHint = MCPCacheHint.privateFor(seconds: 30)

    private let services: MCPToolServices

    public init(services: MCPToolServices) {
        self.services = services
    }

    public func handle(params: JsonValue?, context: MCPRequestContext) async throws -> MCPResult {
        let cursor = try MCPListPagination.cursorArgument(in: params)
        let resources = await Self.resources(services: services, principal: context.principal)
        let page = try MCPListPagination.page(resources, cursor: cursor, method: Self.method)

        var payload: [String: JsonValue] = ["resources": .array(page.items)]
        if let nextCursor = page.nextCursor {
            payload["nextCursor"] = .string(nextCursor)
        }

        Self.logger.debug(
            """
            resources/list page=\(page.items.count, privacy: .public) \
            total=\(resources.count, privacy: .public)
            """
        )
        return .complete(payload, cacheHint: Self.cacheHint)
    }

    private struct ConnectedConnection: Sendable {
        let id: UUID
        let name: String
    }

    private static func resources(services: MCPToolServices, principal: MCPPrincipal) async -> [JsonValue] {
        var resources: [JsonValue] = [connectionsResource()]
        for connection in await connectedConnections(services: services, principal: principal) {
            resources.append(contentsOf: connectionResources(for: connection))
        }
        return resources
    }

    private static func connectedConnections(
        services: MCPToolServices,
        principal: MCPPrincipal
    ) async -> [ConnectedConnection] {
        let value = await services.connectionBridge.listConnections(principal: principal)
        guard let entries = value["connections"]?.arrayValue else { return [] }

        return entries
            .compactMap { entry -> ConnectedConnection? in
                guard let rawId = entry["id"]?.stringValue, let id = UUID(uuidString: rawId) else { return nil }
                guard entry["is_connected"]?.boolValue == true else { return nil }
                return ConnectedConnection(id: id, name: entry["name"]?.stringValue ?? rawId)
            }
            .sorted { lhs, rhs in
                let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if order != .orderedSame { return order == .orderedAscending }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    private static func connectionsResource() -> JsonValue {
        resource(
            uri: ResourcesUriRoute.connectionsUri(),
            name: "connections",
            title: String(localized: "Saved Connections"),
            description: String(localized: "Every saved connection this client may use, with its live session state")
        )
    }

    private static func connectionResources(for connection: ConnectedConnection) -> [JsonValue] {
        let id = connection.id
        let name = connection.name
        return [
            resource(
                uri: ResourcesUriRoute.schemaUri(connectionId: id),
                name: "connections/\(id.uuidString)/schema",
                title: String(format: String(localized: "Schema of %@"), name),
                description: String(localized: "Tables and columns of the database this connection is browsing")
            ),
            resource(
                uri: ResourcesUriRoute.tablesUri(connectionId: id),
                name: "connections/\(id.uuidString)/tables",
                title: String(format: String(localized: "Tables of %@"), name),
                description: String(localized: "Table and view names, without columns")
            ),
            resource(
                uri: ResourcesUriRoute.databasesUri(connectionId: id),
                name: "connections/\(id.uuidString)/databases",
                title: String(format: String(localized: "Databases of %@"), name),
                description: String(localized: "Database names this connection can reach")
            ),
            resource(
                uri: ResourcesUriRoute.historyUri(connectionId: id),
                name: "connections/\(id.uuidString)/history",
                title: String(format: String(localized: "Query history of %@"), name),
                description: String(localized: "Queries recently run against this connection, newest first")
            )
        ]
    }

    private static func resource(uri: String, name: String, title: String, description: String) -> JsonValue {
        .object([
            "uri": .string(uri),
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "mimeType": .string(ResourcesUriRoute.mimeType)
        ])
    }
}
