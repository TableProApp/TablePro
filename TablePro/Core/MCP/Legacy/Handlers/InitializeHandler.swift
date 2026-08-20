import Foundation

public struct InitializeHandler: MCPMethodHandler {
    public static let method = "initialize"
    public static let requiredScopes: Set<MCPScope> = []
    public static let isAvailableToModernClients = false
    public static let isAvailableToLegacyClients = true

    public init() {}

    public func handle(params: JsonValue?, context: MCPRequestContext) async throws -> MCPResult {
        let negotiated = try Self.negotiate(requestedVersion: params?["protocolVersion"]?.stringValue)
        return Self.result(protocolVersion: negotiated)
    }

    public static func negotiate(requestedVersion: String?) throws -> MCPProtocolVersion {
        guard let requestedVersion, !requestedVersion.isEmpty else {
            throw MCPProtocolError.unsupportedProtocolVersion(requested: nil)
        }
        let requested = MCPProtocolVersion(requestedVersion)
        guard MCPProtocolVersion.legacy.contains(requested) else {
            throw MCPProtocolError.unsupportedProtocolVersion(requested: requestedVersion)
        }
        return requested
    }

    public static func result(protocolVersion: MCPProtocolVersion) -> MCPResult {
        MCPResult.complete([
            "protocolVersion": .string(protocolVersion.rawValue),
            "capabilities": MCPMethodRegistry.capabilities().asJsonValue(era: .legacy),
            "serverInfo": MCPMethodRegistry.serverInfo.asJsonValue,
            "instructions": .string(MCPMethodRegistry.instructions)
        ])
    }
}
