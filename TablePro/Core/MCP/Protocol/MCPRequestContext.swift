import Foundation

public struct MCPRequestContext: Sendable {
    public let exchange: MCPInboundExchange
    public let session: MCPSession
    public let principal: MCPPrincipal
    public let dispatcher: MCPProtocolDispatcher
    public let progress: MCPProgressEmitter
    public let cancellation: MCPCancellationToken
    public let clock: any MCPClock

    public init(
        exchange: MCPInboundExchange,
        session: MCPSession,
        principal: MCPPrincipal,
        dispatcher: MCPProtocolDispatcher,
        progress: MCPProgressEmitter,
        cancellation: MCPCancellationToken,
        clock: any MCPClock
    ) {
        self.exchange = exchange
        self.session = session
        self.principal = principal
        self.dispatcher = dispatcher
        self.progress = progress
        self.cancellation = cancellation
        self.clock = clock
    }

    public var requestId: JsonRpcId? {
        if case .request(let request) = exchange.message {
            return request.id
        }
        return nil
    }

    public var sessionId: MCPSessionId {
        session.id
    }

    public var requestParams: JsonValue? {
        if case .request(let request) = exchange.message {
            return request.params
        }
        if case .notification(let notification) = exchange.message {
            return notification.params
        }
        return nil
    }
}
