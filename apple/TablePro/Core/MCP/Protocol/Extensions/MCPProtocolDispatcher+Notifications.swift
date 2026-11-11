import Foundation
import os
import TableProMCP

extension MCPProtocolDispatcher {
    internal func handleNotification(_ notification: JsonRpcNotification, exchange: MCPInboundExchange) async {
        if notification.method == Self.cancelledNotificationMethod {
            await handleCancellation(notification, exchange: exchange)
        } else {
            Self.logger.debug("Dropping notification \(notification.method, privacy: .public)")
        }
        await exchange.responder.acknowledgeAccepted()
    }

    private func handleCancellation(_ notification: JsonRpcNotification, exchange: MCPInboundExchange) async {
        guard let principal = exchange.context.principal else {
            Self.logger.debug("Dropping cancellation from an unauthenticated caller")
            return
        }
        guard let requestId = Self.cancellationRequestId(in: notification.params) else {
            Self.logger.debug("Dropping cancellation without a usable requestId")
            return
        }
        guard let key = await cancellationKey(
            requestId: requestId,
            params: notification.params,
            principal: principal,
            exchange: exchange
        ) else {
            Self.logger.debug("Dropping a cancellation that does not say which stdio client sent it")
            return
        }
        let reason = notification.params?["reason"]?.stringValue
        let cancelled = await inflight.cancel(key: key, reason: .clientRequested(reason))
        guard !cancelled else { return }
        Self.logger.debug("Cancellation referenced a request that is no longer in flight")
    }

    // The sender is resolved the way its request was, so a cancellation reaches only that client's request.
    private func cancellationKey(
        requestId: JsonRpcId,
        params: JsonValue?,
        principal: MCPPrincipal,
        exchange: MCPInboundExchange
    ) async -> MCPInflightKey? {
        guard principal.metadata.isBridgeCredential else {
            return MCPInflightKey(principal: principal, requestId: requestId)
        }
        if let bridgeInstance = MCPRequestMeta.bridgeInstance(in: params) {
            return MCPInflightKey(bridgeInstance: bridgeInstance, requestId: requestId)
        }
        let meta: MCPRequestMeta
        switch try? await legacyAdapter.resolve(message: exchange.message, inbound: exchange.context) {
        case .modern(let resolved)?, .legacy(let resolved, _)?:
            meta = resolved
        case .legacyInitialize?, nil:
            return nil
        }
        let client = MCPClientIdentity(meta: meta, principal: principal, address: exchange.context.clientAddress)
        return MCPInflightKey(client: client, requestId: requestId)
    }

    internal static func cancellationRequestId(in params: JsonValue?) -> JsonRpcId? {
        switch params?["requestId"] {
        case .string(let value):
            return .string(value)
        case .int(let value):
            return .number(Int64(value))
        case .double(let value):
            guard value.magnitude <= Self.exactDoubleIntegerLimit, let exact = Int64(exactly: value) else {
                return nil
            }
            return .number(exact)
        default:
            return nil
        }
    }
}
