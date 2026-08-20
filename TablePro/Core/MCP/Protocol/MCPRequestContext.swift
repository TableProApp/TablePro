import Foundation

public struct MCPRequestContext: Sendable {
    public let requestId: JsonRpcId
    public let params: JsonValue?
    public let meta: MCPRequestMeta
    public let principal: MCPPrincipal
    public let responder: MCPResponder
    public let progress: MCPProgressEmitter
    public let cancellation: MCPCancellationToken
    public let clock: any MCPClock
    public let clientAddress: MCPClientAddress
    public let receivedAt: Date

    public init(
        requestId: JsonRpcId,
        params: JsonValue?,
        meta: MCPRequestMeta,
        principal: MCPPrincipal,
        responder: MCPResponder,
        progress: MCPProgressEmitter,
        cancellation: MCPCancellationToken,
        clock: any MCPClock,
        clientAddress: MCPClientAddress,
        receivedAt: Date
    ) {
        self.requestId = requestId
        self.params = params
        self.meta = meta
        self.principal = principal
        self.responder = responder
        self.progress = progress
        self.cancellation = cancellation
        self.clock = clock
        self.clientAddress = clientAddress
        self.receivedAt = receivedAt
    }

    public var era: MCPEra {
        meta.era
    }

    public var protocolVersion: MCPProtocolVersion {
        meta.protocolVersion
    }

    public var clientCapabilities: MCPClientCapabilities {
        meta.clientCapabilities
    }

    public func throwIfCancelled() async throws {
        if await cancellation.isCancelled {
            throw CancellationError()
        }
    }
}
