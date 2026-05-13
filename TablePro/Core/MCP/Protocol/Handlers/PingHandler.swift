import Foundation

public struct PingHandler: MCPMethodHandler {
    public static let method = "ping"
    public static let requiredScopes: Set<MCPScope> = []
    public static let allowedSessionStates: Set<MCPSessionAllowedState> = [.uninitialized, .ready]

    public init() {}

    public func handle(params: JsonValue?, context: MCPRequestContext) async throws -> JsonRpcMessage {
        await context.session.touch(now: await context.clock.now())
        return MCPMethodHandlerHelpers.successResponse(
            id: context.requestId,
            result: .object([:])
        )
    }
}
