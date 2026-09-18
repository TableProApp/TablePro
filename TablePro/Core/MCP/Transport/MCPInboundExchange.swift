import Foundation

public struct MCPInboundContext: Sendable {
    public let principal: MCPPrincipal?
    public let clientAddress: MCPClientAddress
    public let receivedAt: Date
    public let transportProtocolVersion: String?
    public let legacySessionId: MCPLegacySessionId?

    public init(
        principal: MCPPrincipal?,
        clientAddress: MCPClientAddress,
        receivedAt: Date,
        transportProtocolVersion: String?,
        legacySessionId: MCPLegacySessionId? = nil
    ) {
        self.principal = principal
        self.clientAddress = clientAddress
        self.receivedAt = receivedAt
        self.transportProtocolVersion = transportProtocolVersion
        self.legacySessionId = legacySessionId
    }
}

public struct MCPInboundExchange: Sendable {
    public let message: JsonRpcMessage
    public let context: MCPInboundContext
    public let responder: MCPResponder

    public init(message: JsonRpcMessage, context: MCPInboundContext, responder: MCPResponder) {
        self.message = message
        self.context = context
        self.responder = responder
    }
}
