import Foundation

public struct PingHandler: MCPMethodHandler {
    public static let method = "ping"
    public static let requiredScopes: Set<MCPScope> = []
    public static let isAvailableToModernClients = false
    public static let isAvailableToLegacyClients = true

    public init() {}

    public func handle(params: JsonValue?, context: MCPRequestContext) async throws -> MCPResult {
        MCPResult.empty
    }
}
