import Foundation
import os

public struct SubscriptionsListenHandler: MCPMethodHandler {
    public static let method = "subscriptions/listen"
    public static let requiredScopes: Set<MCPScope> = []
    public static let isAvailableToLegacyClients = false

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Subscriptions")

    private let subscriptions: MCPSubscriptionRegistry

    public init(subscriptions: MCPSubscriptionRegistry) {
        self.subscriptions = subscriptions
    }

    public func handle(params: JsonValue?, context: MCPRequestContext) async throws -> MCPResult {
        guard let subscriptionId = MCPSubscriptionId(requestId: context.requestId) else {
            throw MCPProtocolError.invalidParams(detail: "subscriptions/listen requires a non-null request id")
        }
        let requested = try MCPSubscriptionFilter.decode(params: params)
        let honoured = requested.honoured(for: context.principal)
        try await context.throwIfCancelled()

        await context.responder.beginStream()
        await context.responder.emit(
            MCPSubscriptionNotification.acknowledgment(subscriptionId: subscriptionId, filter: honoured)
        )

        let acknowledged = await subscriptions.open(
            id: context.requestId,
            filter: honoured,
            responder: context.responder,
            principal: context.principal
        )
        Self.logger.debug(
            """
            subscriptions/listen id=\(subscriptionId.description, privacy: .public) \
            honoured=\(acknowledged.asJsonValue.jsonString(), privacy: .public)
            """
        )

        await awaitClosure(requestId: context.requestId, cancellation: context.cancellation)

        var closed = MCPResult.empty
        closed.meta.subscriptionId = context.requestId
        return closed
    }

    private func awaitClosure(requestId: JsonRpcId, cancellation: MCPCancellationToken) async {
        let registry = subscriptions
        await cancellation.onCancel { _ in
            await registry.close(id: requestId)
        }
        await withTaskCancellationHandler {
            await registry.awaitClosure(id: requestId)
        } onCancel: {
            Task { await registry.close(id: requestId) }
        }
        await registry.close(id: requestId)
    }
}
