import Foundation

enum MCPToolAuthorization {
    static func readableConnectionIds(
        context: MCPRequestContext,
        services: MCPToolServices
    ) async -> Set<UUID> {
        await services.authPolicy.readableConnectionIds(principal: context.principal)
    }

    static func requireReadAccess(
        _ connectionId: UUID,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws {
        let readable = await readableConnectionIds(context: context, services: services)
        guard readable.contains(connectionId) else {
            throw MCPToolExecutionError.denied(
                String(localized: "This client does not have access to that connection.")
            )
        }
    }

    static func requireScope(
        _ scope: MCPScope,
        context: MCPRequestContext,
        reason: String
    ) throws {
        guard context.principal.scopes.contains(scope) else {
            throw MCPProtocolError.insufficientScope(required: [scope], reason: reason)
        }
    }
}
