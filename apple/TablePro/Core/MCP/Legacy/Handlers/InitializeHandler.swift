import Foundation
import TableProMCP

public struct InitializeHandler: MCPMethodHandler {
    public static let method = "initialize"
    public static let requiredScopes: Set<MCPScope> = []
    public static let isAvailableToModernClients = false
    public static let isAvailableToLegacyClients = true

    public init() {}

    public func handle(params: JsonValue?, context: MCPRequestContext) async throws -> MCPResult {
        let negotiated = try Self.negotiate(requestedVersion: params?["protocolVersion"]?.stringValue)
        return Self.result(protocolVersion: negotiated, scopes: context.principal.scopes)
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

    public static func result(protocolVersion: MCPProtocolVersion, scopes: Set<MCPScope>) -> MCPResult {
        MCPResult.complete([
            "protocolVersion": .string(protocolVersion.rawValue),
            "capabilities": capabilities(for: scopes).asJsonValue(era: .legacy),
            "serverInfo": MCPMethodRegistry.serverInfo.asJsonValue,
            "instructions": .string(MCPMethodRegistry.instructions)
        ])
    }

    // A client told it has resources or prompts lists them at connect, and a 403 there can end the session.
    static func capabilities(for scopes: Set<MCPScope>) -> MCPServerCapabilities {
        let all = MCPMethodRegistry.capabilities()
        let readsResources = scopes.contains(.resourcesRead)
        return MCPServerCapabilities(
            tools: scopes.contains(.toolsRead) ? all.tools : nil,
            resources: readsResources ? all.resources : nil,
            prompts: readsResources ? all.prompts : nil,
            completions: readsResources && all.completions,
            extensions: all.extensions
        )
    }
}
