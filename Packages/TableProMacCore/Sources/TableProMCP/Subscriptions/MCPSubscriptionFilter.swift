import Foundation

public enum MCPSubscribableResource: Sendable, Equatable, Hashable {
    case connectionSchema(connectionId: UUID)

    public init?(uri: String) {
        guard let route = try? ResourcesUriRoute.parse(uri: uri) else { return nil }
        guard case .connectionSchema(let connectionId) = route else { return nil }
        self = .connectionSchema(connectionId: connectionId)
    }

    public var uri: String {
        ResourcesUriRoute.schemaUri(connectionId: connectionId)
    }

    public var connectionId: UUID {
        switch self {
        case .connectionSchema(let connectionId):
            return connectionId
        }
    }
}

public struct MCPSubscriptionFilter: Sendable, Equatable {
    public let toolsListChanged: Bool
    public let promptsListChanged: Bool
    public let resourcesListChanged: Bool
    public let resourceSubscriptions: [String]

    public init(
        toolsListChanged: Bool = false,
        promptsListChanged: Bool = false,
        resourcesListChanged: Bool = false,
        resourceSubscriptions: [String] = []
    ) {
        self.toolsListChanged = toolsListChanged
        self.promptsListChanged = promptsListChanged
        self.resourcesListChanged = resourcesListChanged
        var seen: Set<String> = []
        self.resourceSubscriptions = resourceSubscriptions.filter { seen.insert($0).inserted }
    }

    public static let none = MCPSubscriptionFilter()

    public var isEmpty: Bool {
        !toolsListChanged && !promptsListChanged && !resourcesListChanged && resourceSubscriptions.isEmpty
    }

    public func includes(resourceUri: String) -> Bool {
        resourceSubscriptions.contains(resourceUri)
    }

    public var asJsonValue: JsonValue {
        var fields: [String: JsonValue] = [:]
        if toolsListChanged {
            fields["toolsListChanged"] = .bool(true)
        }
        if promptsListChanged {
            fields["promptsListChanged"] = .bool(true)
        }
        if resourcesListChanged {
            fields["resourcesListChanged"] = .bool(true)
        }
        if !resourceSubscriptions.isEmpty {
            fields["resourceSubscriptions"] = .array(resourceSubscriptions.map { .string($0) })
        }
        return .object(fields)
    }
}

public extension MCPSubscriptionFilter {
    static func decode(params: JsonValue?) throws -> MCPSubscriptionFilter {
        guard let params, params.objectValue != nil else {
            throw MCPProtocolError.invalidParams(detail: "Missing required parameter: notifications")
        }
        guard let notifications = params["notifications"] else {
            throw MCPProtocolError.invalidParams(detail: "Missing required parameter: notifications")
        }
        guard let fields = notifications.objectValue else {
            throw MCPProtocolError.invalidParams(detail: "notifications must be an object")
        }
        return MCPSubscriptionFilter(
            toolsListChanged: try flag(fields["toolsListChanged"], named: "toolsListChanged"),
            promptsListChanged: try flag(fields["promptsListChanged"], named: "promptsListChanged"),
            resourcesListChanged: try flag(fields["resourcesListChanged"], named: "resourcesListChanged"),
            resourceSubscriptions: try uriList(fields["resourceSubscriptions"])
        )
    }

    func honoured(for principal: MCPPrincipal) -> MCPSubscriptionFilter {
        guard principal.has(.resourcesRead) else { return .none }
        let uris = resourceSubscriptions.compactMap { uri -> String? in
            guard let resource = MCPSubscribableResource(uri: uri) else { return nil }
            guard principal.connectionAccess.allows(resource.connectionId) else { return nil }
            return resource.uri
        }
        return MCPSubscriptionFilter(
            resourcesListChanged: resourcesListChanged,
            resourceSubscriptions: uris
        )
    }

    private static func flag(_ value: JsonValue?, named name: String) throws -> Bool {
        guard let value, !value.isNull else { return false }
        guard let flag = value.boolValue else {
            throw MCPProtocolError.invalidParams(detail: "notifications.\(name) must be a boolean")
        }
        return flag
    }

    private static func uriList(_ value: JsonValue?) throws -> [String] {
        guard let value, !value.isNull else { return [] }
        guard let entries = value.arrayValue else {
            throw MCPProtocolError.invalidParams(detail: "notifications.resourceSubscriptions must be an array")
        }
        return try entries.map { entry in
            guard let uri = entry.stringValue, !uri.isEmpty else {
                throw MCPProtocolError.invalidParams(
                    detail: "notifications.resourceSubscriptions must contain non-empty strings"
                )
            }
            return uri
        }
    }
}
