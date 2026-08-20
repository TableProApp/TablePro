import Foundation
import os

public protocol MCPResponderSink: Sendable {
    func writeJson(_ data: Data, status: HttpStatus, extraHeaders: [(String, String)]) async
    func writeAccepted() async
    func beginSseStream() async
    func writeSseFrame(_ frame: SseFrame) async
    func closeConnection() async
    func isClosed() async -> Bool
}

public actor MCPResponder {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Responder")

    private static let staticInternalErrorEnvelope = Data(
        #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"internal_error"}}"#.utf8
    )

    private let sink: MCPResponderSink
    private let requestId: JsonRpcId?
    private var streaming = false
    private var completed = false

    public init(sink: MCPResponderSink, requestId: JsonRpcId?) {
        self.sink = sink
        self.requestId = requestId
    }

    public var isStreaming: Bool {
        streaming
    }

    public func beginStream() async {
        guard !completed, !streaming else { return }
        streaming = true
        await sink.beginSseStream()
    }

    public func emit(_ notification: JsonRpcMessage) async {
        guard !completed else { return }
        await beginStream()
        guard let payload = try? JsonRpcCodec.encode(notification),
              let text = String(data: payload, encoding: .utf8) else { return }
        await sink.writeSseFrame(SseFrame(data: text))
    }

    public func respond(_ message: JsonRpcMessage, extraHeaders: [(String, String)] = []) async {
        guard !completed else {
            Self.logger.warning("Responder.respond called after completion; ignoring")
            return
        }
        completed = true
        let body = encode(message)
        if streaming {
            if let text = String(data: body, encoding: .utf8) {
                await sink.writeSseFrame(SseFrame(data: text))
            }
        } else {
            await sink.writeJson(body, status: .ok, extraHeaders: extraHeaders)
        }
        await sink.closeConnection()
    }

    public func respondError(_ error: MCPProtocolError, requestId responseId: JsonRpcId? = nil) async {
        guard !completed else {
            Self.logger.warning("Responder.respondError called after completion; ignoring")
            return
        }
        completed = true
        let envelope = error.toJsonRpcErrorResponse(id: responseId ?? requestId)
        let data = encode(.errorResponse(envelope))
        if streaming {
            if let text = String(data: data, encoding: .utf8) {
                await sink.writeSseFrame(SseFrame(data: text))
            }
        } else {
            await sink.writeJson(data, status: error.httpStatus, extraHeaders: error.extraHeaders)
        }
        await sink.closeConnection()
    }

    public func acknowledgeAccepted() async {
        guard !completed else { return }
        completed = true
        await sink.writeAccepted()
        await sink.closeConnection()
    }

    public func clientDisconnected() async -> Bool {
        await sink.isClosed()
    }

    private func encode(_ message: JsonRpcMessage) -> Data {
        do {
            return try JsonRpcCodec.encode(message)
        } catch {
            Self.logger.error("Encode response failed: \(error.localizedDescription, privacy: .public)")
            let fallback = MCPProtocolError
                .internalError(detail: "encode failed")
                .toJsonRpcErrorResponse(id: requestId)
            return (try? JSONEncoder().encode(fallback)) ?? Self.staticInternalErrorEnvelope
        }
    }
}
