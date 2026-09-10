import Foundation
import os

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
        let key = MCPInflightKey(principal: principal, requestId: requestId)
        let reason = notification.params?["reason"]?.stringValue
        let cancelled = await inflight.cancel(key: key, reason: .clientRequested(reason))
        guard !cancelled else { return }
        Self.logger.debug("Cancellation referenced a request that is no longer in flight")
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
