import Foundation

public struct ToolsListHandler: MCPMethodHandler {
    public static let method = "tools/list"
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let allowedSessionStates: Set<MCPSessionAllowedState> = [.ready]

    public init() {}

    public func handle(params: JsonValue?, context: MCPRequestContext) async throws -> JsonRpcMessage {
        let tools: [JsonValue] = MCPToolRegistry.allTools.map { tool in
            let toolType = type(of: tool)
            var fields: [String: JsonValue] = [
                "name": .string(toolType.name),
                "description": .string(toolType.description),
                "inputSchema": toolType.inputSchema
            ]
            if let title = toolType.title {
                fields["title"] = .string(title)
            }
            if let annotationsValue = toolType.annotations.asJsonValue {
                fields["annotations"] = annotationsValue
            }
            return .object(fields)
        }
        let result: JsonValue = .object(["tools": .array(tools)])
        return MCPMethodHandlerHelpers.successResponse(id: context.requestId, result: result)
    }
}
