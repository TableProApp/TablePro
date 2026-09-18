import Foundation
import TableProPluginKit
@testable import TablePro

enum MCPProtocolHandlerTestSupport {
    static func makeContext(
        method: String = "test/stub",
        params: JsonValue? = nil,
        principalScopes: Set<MCPScope> = [.toolsRead, .toolsWrite],
        principal: MCPPrincipal? = nil,
        era: MCPEra = .modern,
        protocolVersion: MCPProtocolVersion? = nil,
        clientCapabilities: MCPClientCapabilities = .none,
        progressToken: MCPProgressToken? = nil,
        requestId: JsonRpcId = .number(1),
        clock: any MCPClock = MCPSystemClock(),
        clientAddress: MCPClientAddress = .loopback,
        receivedAt: Date = MCPProtocolTestSupport.referenceDate,
        cancellation: MCPCancellationToken = MCPCancellationToken()
    ) async -> MCPRequestContext {
        await makeContextAndSink(
            method: method,
            params: params,
            principalScopes: principalScopes,
            principal: principal,
            era: era,
            protocolVersion: protocolVersion,
            clientCapabilities: clientCapabilities,
            progressToken: progressToken,
            requestId: requestId,
            clock: clock,
            clientAddress: clientAddress,
            receivedAt: receivedAt,
            cancellation: cancellation
        ).context
    }

    static func makeContextAndSink(
        method: String = "test/stub",
        params: JsonValue? = nil,
        principalScopes: Set<MCPScope> = [.toolsRead, .toolsWrite],
        principal: MCPPrincipal? = nil,
        era: MCPEra = .modern,
        protocolVersion: MCPProtocolVersion? = nil,
        clientCapabilities: MCPClientCapabilities = .none,
        progressToken: MCPProgressToken? = nil,
        requestId: JsonRpcId = .number(1),
        clock: any MCPClock = MCPSystemClock(),
        clientAddress: MCPClientAddress = .loopback,
        receivedAt: Date = MCPProtocolTestSupport.referenceDate,
        cancellation: MCPCancellationToken = MCPCancellationToken()
    ) async -> (context: MCPRequestContext, sink: RecordingResponderSink) {
        let resolvedPrincipal = principal ?? MCPProtocolTestSupport.makePrincipal(scopes: principalScopes)
        let meta = MCPProtocolTestSupport.makeMeta(
            protocolVersion: protocolVersion ?? defaultVersion(for: era),
            clientCapabilities: clientCapabilities,
            progressToken: progressToken
        )
        let sink = RecordingResponderSink()
        let responder = MCPResponder(sink: sink, requestId: requestId)
        let context = MCPRequestContext(
            requestId: requestId,
            params: params,
            meta: meta,
            principal: resolvedPrincipal,
            responder: responder,
            progress: MCPProgressEmitter(meta: meta, responder: responder),
            cancellation: cancellation,
            clock: clock,
            clientAddress: clientAddress,
            receivedAt: receivedAt
        )
        return (context, sink)
    }

    static func makeToolServices() -> MCPToolServices {
        MCPToolServices(connectionBridge: MCPConnectionBridge(), authPolicy: MCPAuthPolicy())
    }

    static func defaultVersion(for era: MCPEra) -> MCPProtocolVersion {
        switch era {
        case .modern:
            return .latest
        case .legacy:
            return .v20251125
        }
    }
}
