import Foundation

public enum MCPSessionAllowedState: Sendable, Equatable, Hashable {
    case uninitialized
    case ready
}

public protocol MCPMethodHandler: Sendable {
    static var method: String { get }
    static var requiredScopes: Set<MCPScope> { get }
    static var allowedSessionStates: Set<MCPSessionAllowedState> { get }
    func handle(params: JsonValue?, context: MCPRequestContext) async throws -> JsonRpcMessage
}

public extension MCPMethodHandler {
    var method: String { Self.method }
    var requiredScopes: Set<MCPScope> { Self.requiredScopes }
    var allowedSessionStates: Set<MCPSessionAllowedState> { Self.allowedSessionStates }
}

public enum MCPMethodHandlerHelpers {
    public static func successResponse(id: JsonRpcId?, result: JsonValue) -> JsonRpcMessage {
        guard let id else {
            return .errorResponse(JsonRpcErrorResponse(
                id: nil,
                error: JsonRpcError.invalidRequest(message: "Missing request id")
            ))
        }
        return .successResponse(JsonRpcSuccessResponse(id: id, result: result))
    }

    public static func errorResponse(id: JsonRpcId?, error: MCPProtocolError) -> JsonRpcMessage {
        .errorResponse(error.toJsonRpcErrorResponse(id: id))
    }
}
