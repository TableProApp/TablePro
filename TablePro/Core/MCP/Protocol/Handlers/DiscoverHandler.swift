import Foundation
import os

public struct DiscoverHandler: MCPMethodHandler {
    public static let method = "server/discover"
    public static let requiredScopes: Set<MCPScope> = []
    public static let isAvailableToLegacyClients = false

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Discover")
    private static let cacheHint = MCPCacheHint.publicFor(seconds: 3_600)

    public init() {}

    public func handle(params: JsonValue?, context: MCPRequestContext) async throws -> MCPResult {
        var payload: [String: JsonValue] = [
            "supportedVersions": .array(MCPProtocolVersion.supportedRawValues.map { .string($0) }),
            "capabilities": MCPMethodRegistry.capabilities().asJsonValue(era: context.era)
        ]

        let instructions = MCPMethodRegistry.instructions
        if !instructions.isEmpty {
            payload["instructions"] = .string(instructions)
        }

        let clientName = context.meta.clientInfo?.name ?? "-"
        Self.logger.debug("server/discover client=\(clientName, privacy: .public)")

        var result = MCPResult.complete(payload, cacheHint: Self.cacheHint)
        result.meta.serverInfo = MCPMethodRegistry.serverInfo
        let instanceId = MCPServerInstanceIdentity.shared.current
        if !instanceId.isEmpty {
            result.meta.passthrough[MCPServerInstanceIdentity.metaKey] = .string(instanceId)
        }
        return result
    }
}
