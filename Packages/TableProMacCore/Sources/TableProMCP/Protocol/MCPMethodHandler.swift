import Foundation

public protocol MCPMethodHandler: Sendable {
    static var method: String { get }
    static var requiredScopes: Set<MCPScope> { get }
    static var isAvailableToLegacyClients: Bool { get }
    static var isAvailableToModernClients: Bool { get }
    func handle(params: JsonValue?, context: MCPRequestContext) async throws -> MCPResult
}

public extension MCPMethodHandler {
    static var isAvailableToLegacyClients: Bool { true }
    static var isAvailableToModernClients: Bool { true }

    var method: String { Self.method }
    var requiredScopes: Set<MCPScope> { Self.requiredScopes }
}
