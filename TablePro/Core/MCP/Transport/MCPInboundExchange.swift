import Foundation
import os

public struct MCPInboundContext: Sendable {
    public let sessionId: MCPSessionId?
    public let principal: MCPPrincipal?
    public let clientAddress: MCPClientAddress
    public let receivedAt: Date
    public let mcpProtocolVersion: String?

    public init(
        sessionId: MCPSessionId?,
        principal: MCPPrincipal?,
        clientAddress: MCPClientAddress,
        receivedAt: Date,
        mcpProtocolVersion: String?
    ) {
        self.sessionId = sessionId
        self.principal = principal
        self.clientAddress = clientAddress
        self.receivedAt = receivedAt
        self.mcpProtocolVersion = mcpProtocolVersion
    }
}

public struct MCPInboundExchange: Sendable {
    public let message: JsonRpcMessage
    public let context: MCPInboundContext
    public let responder: MCPExchangeResponder

    public init(
        message: JsonRpcMessage,
        context: MCPInboundContext,
        responder: MCPExchangeResponder
    ) {
        self.message = message
        self.context = context
        self.responder = responder
    }
}

public protocol MCPResponderSink: Sendable {
    func writeJson(_ data: Data, status: HttpStatus, sessionId: MCPSessionId?, extraHeaders: [(String, String)]) async
    func writeAccepted() async
    func writeSseStreamHeaders(sessionId: MCPSessionId) async
    func writeSseFrame(_ frame: SseFrame) async
    func closeConnection() async
    func registerSseConnection(sessionId: MCPSessionId) async
}

public actor MCPExchangeResponder {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.HttpServer")

    private static let staticInternalErrorEnvelope = Data(
        #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"internal_error"}}"#.utf8
    )

    private let sink: MCPResponderSink
    private var completed: Bool = false
    private let requestId: JsonRpcId?

    public init(sink: MCPResponderSink, requestId: JsonRpcId?) {
        self.sink = sink
        self.requestId = requestId
    }

    public func respond(_ message: JsonRpcMessage, sessionId: MCPSessionId?) async {
        guard !completed else {
            Self.logger.warning("Responder.respond called after completion; ignoring")
            return
        }
        completed = true

        let body: Data
        do {
            body = try JsonRpcCodec.encode(message)
        } catch {
            Self.logger.error("Encode response failed: \(error.localizedDescription, privacy: .public)")
            let fallback = MCPProtocolError.internalError(detail: "encode failed").toJsonRpcErrorResponse(id: requestId)
            do {
                body = try JSONEncoder().encode(fallback)
            } catch {
                Self.logger.error("Encode internal_error envelope failed: \(error.localizedDescription, privacy: .public); using static fallback")
                body = Self.staticInternalErrorEnvelope
            }
        }

        await sink.writeJson(body, status: .ok, sessionId: sessionId, extraHeaders: [])
        await sink.closeConnection()
    }

    public func respondError(_ error: MCPProtocolError, requestId responseId: JsonRpcId?) async {
        guard !completed else {
            Self.logger.warning("Responder.respondError called after completion; ignoring")
            return
        }
        completed = true

        let envelope = error.toJsonRpcErrorResponse(id: responseId ?? requestId)
        let data: Data
        do {
            data = try JSONEncoder().encode(envelope)
        } catch {
            Self.logger.error("Encode error envelope failed: \(error.localizedDescription, privacy: .public); using static fallback")
            data = Self.staticInternalErrorEnvelope
        }
        await sink.writeJson(data, status: error.httpStatus, sessionId: nil, extraHeaders: error.extraHeaders)
        await sink.closeConnection()
    }

    public func respondSseStream(
        initialMessage: JsonRpcMessage?,
        sessionId: MCPSessionId,
        additional: AsyncStream<JsonRpcMessage>
    ) async {
        guard !completed else {
            Self.logger.warning("Responder.respondSseStream called after completion; ignoring")
            return
        }
        completed = true

        await sink.writeSseStreamHeaders(sessionId: sessionId)
        await sink.registerSseConnection(sessionId: sessionId)

        if let initialMessage {
            if let payload = try? JsonRpcCodec.encode(initialMessage),
               let text = String(data: payload, encoding: .utf8) {
                await sink.writeSseFrame(SseFrame(data: text))
            }
        }

        for await message in additional {
            guard let payload = try? JsonRpcCodec.encode(message),
                  let text = String(data: payload, encoding: .utf8) else { continue }
            await sink.writeSseFrame(SseFrame(data: text))
        }
    }

    public func acknowledgeAccepted() async {
        guard !completed else {
            Self.logger.warning("Responder.acknowledgeAccepted called after completion; ignoring")
            return
        }
        completed = true
        await sink.writeAccepted()
        await sink.closeConnection()
    }

    public func reject(_ error: MCPProtocolError) async {
        guard !completed else {
            Self.logger.warning("Responder.reject called after completion; ignoring")
            return
        }
        completed = true

        let envelope = error.toJsonRpcErrorResponse(id: requestId)
        let data: Data
        do {
            data = try JSONEncoder().encode(envelope)
        } catch {
            Self.logger.error("Encode reject envelope failed: \(error.localizedDescription, privacy: .public); using static fallback")
            data = Self.staticInternalErrorEnvelope
        }
        await sink.writeJson(data, status: error.httpStatus, sessionId: nil, extraHeaders: error.extraHeaders)
        await sink.closeConnection()
    }
}
