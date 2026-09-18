import Foundation
import os

internal extension MCPHttpRequestRouter {
    func handleRpc(head: HttpRequestHead, body: Data, context: HttpConnectionContext) async {
        let clientAddress = await context.clientAddress()
        let receivedAt = await clock.now()

        guard Self.carriesJsonBody(head) else {
            await respondProtocolError(
                context: context,
                error: MCPProtocolError(
                    code: JsonRpcErrorCode.invalidRequest,
                    message: "Content-Type must be application/json",
                    httpStatus: .unsupportedMediaType
                ),
                requestId: nil
            )
            return
        }

        let authResult = await authenticate(headers: head.headers, clientAddress: clientAddress)
        guard case .allow(let principal) = authResult else {
            if case .deny(let error) = authResult {
                await respondProtocolError(context: context, error: error, requestId: nil)
            }
            return
        }

        let message: JsonRpcMessage
        do {
            message = try JsonRpcCodec.decode(body)
        } catch {
            await respondProtocolError(
                context: context,
                error: .parseError(detail: String(describing: error)),
                requestId: nil
            )
            return
        }

        switch message {
        case .successResponse, .errorResponse:
            await respondProtocolError(
                context: context,
                error: .invalidRequest(detail: "Clients must not send JSON-RPC responses"),
                requestId: nil
            )
            return
        case .request, .notification:
            break
        }

        let requestId = Self.requestId(of: message)
        let isModern = MCPRequestMeta.declaresModernProtocol(params: Self.params(of: message))

        if isModern, let failure = MCPHttpHeaderValidator.validate(head: head, message: message) {
            Self.logger.warning("Header validation failed: \(failure.message, privacy: .public)")
            await respondProtocolError(context: context, error: failure, requestId: requestId)
            return
        }

        var legacySessionId: MCPLegacySessionId?
        if !isModern, let raw = head.headers.value(for: "Mcp-Session-Id"), !raw.isEmpty {
            legacySessionId = MCPLegacySessionId(rawValue: raw)
        }

        let responder = MCPResponder(sink: MCPHttpResponderSink(context: context), requestId: requestId)
        let inbound = MCPInboundContext(
            principal: principal,
            clientAddress: clientAddress,
            receivedAt: receivedAt,
            transportProtocolVersion: head.headers.value(for: MCPHttpHeaderValidator.protocolVersionHeader),
            legacySessionId: legacySessionId
        )
        let exchange = MCPInboundExchange(message: message, context: inbound, responder: responder)

        if case .enqueued = emitInbound(exchange) { return }

        Self.logger.error("Inbound exchange queue is full; answering 503 instead of dropping the request")
        await responder.respondError(.serviceUnavailable())
    }

    static func carriesJsonBody(_ head: HttpRequestHead) -> Bool {
        guard let raw = head.headers.value(for: "Content-Type") else { return false }
        guard let mediaType = raw.split(separator: ";").first else { return false }
        let normalized = mediaType.trimmingCharacters(in: .whitespaces).lowercased()
        return normalized == "application/json" || normalized.hasSuffix("+json")
    }

    static func requestId(of message: JsonRpcMessage) -> JsonRpcId? {
        switch message {
        case .request(let request):
            return request.id
        case .successResponse(let response):
            return response.id
        case .errorResponse(let response):
            return response.id
        case .notification:
            return nil
        }
    }

    static func params(of message: JsonRpcMessage) -> JsonValue? {
        switch message {
        case .request(let request):
            return request.params
        case .notification(let notification):
            return notification.params
        case .successResponse, .errorResponse:
            return nil
        }
    }
}
