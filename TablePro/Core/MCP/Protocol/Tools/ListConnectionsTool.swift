import Foundation

public struct ListConnectionsTool: MCPToolImplementation {
    public static let name = "list_connections"
    public static let title: String? = String(localized: "List Connections")
    public static let description = String(
        localized: """
        List the saved database connections this client may use, with their live status. \
        Connections the token cannot reach, or that the user blocked for external clients, are omitted.
        """
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "List Connections"),
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    public static let inputSchema = MCPToolSchema.object(
        properties: [
            "purpose": MCPToolSchema.string(
                String(
                    localized: """
                    Leave out, or send agent, for the connections an AI client may use. display is for a \
                    launcher showing the list to the user: it needs the connections:display scope and adds \
                    connections hidden from AI, with user names.
                    """
                ),
                enumValues: MCPConnectionListPurpose.allCases.map(\.rawValue)
            )
        ]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.object(
        properties: [
            "connections": MCPToolSchema.array(
                String(localized: "Connections the client may use, ordered by name"),
                of: MCPToolSchema.object(
                    properties: [
                        "id": MCPToolSchema.string(String(localized: "Connection UUID")),
                        "name": MCPToolSchema.string(String(localized: "Display name")),
                        "type": MCPToolSchema.string(String(localized: "Database engine")),
                        "host": MCPToolSchema.string(String(localized: "Server host")),
                        "port": MCPToolSchema.integer(String(localized: "Server port")),
                        "database": MCPToolSchema.string(String(localized: "Current database")),
                        "is_connected": MCPToolSchema.boolean(String(localized: "Whether a session is open")),
                        "ai_policy": MCPToolSchema.string(String(localized: "AI access policy")),
                        "external_access": MCPToolSchema.string(String(localized: "External client access level")),
                        "safe_mode": MCPToolSchema.string(String(localized: "Safe mode level")),
                        "username": MCPToolSchema.string(String(localized: "User name, sent only for purpose display")),
                        "color": colorSchema,
                        "group": MCPToolSchema.object(
                            properties: [
                                "id": MCPToolSchema.string(String(localized: "Group UUID")),
                                "name": MCPToolSchema.string(String(localized: "Group name")),
                                "path": MCPToolSchema.array(
                                    String(localized: "Group names from the top-level group down to this one"),
                                    of: MCPToolSchema.stringItem
                                ),
                                "color": colorSchema
                            ],
                            required: ["id", "name", "path"]
                        ),
                        "tags": MCPToolSchema.array(
                            String(localized: "Tags on the connection"),
                            of: MCPToolSchema.object(
                                properties: [
                                    "id": MCPToolSchema.string(String(localized: "Tag UUID")),
                                    "name": MCPToolSchema.string(String(localized: "Tag name")),
                                    "color": colorSchema
                                ],
                                required: ["id", "name"]
                            )
                        )
                    ],
                    required: ["id", "name", "type", "host", "port", "database", "is_connected", "tags"]
                )
            )
        ],
        required: ["connections"]
    )

    private static let colorSchema = MCPToolSchema.string(
        String(localized: "Color, omitted when none"),
        enumValues: ConnectionColor.allCases.compactMap(\.externalName)
    )

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(arguments, allowed: ["purpose"])
        let purpose = try MCPArgumentDecoder.optionalEnum(
            arguments,
            key: "purpose",
            allowed: MCPConnectionListPurpose.allCases.map(\.rawValue)
        ).flatMap(MCPConnectionListPurpose.init(rawValue:)) ?? .agent

        if purpose == .display {
            try await Self.requireDisplayGrant(context: context, services: services)
        }

        let payload = await services.connectionBridge.listConnections(principal: context.principal, purpose: purpose)
        return .structured(payload)
    }

    /// The scope is granted per token at pairing; the setting is the user's switch for all of them,
    /// so turning it off stops every token at once.
    private static func requireDisplayGrant(context: MCPRequestContext, services: MCPToolServices) async throws {
        try context.principal.requireScopes(
            [.connectionsDisplay],
            reason: "Listing connections for display needs the connections:display scope"
        )
        guard await services.settingsProvider().allowsHiddenConnectionListing else {
            throw MCPProtocolError.insufficientScope(
                required: [.connectionsDisplay],
                reason: "Listing connections hidden from AI is turned off in Settings > MCP"
            )
        }
    }
}
