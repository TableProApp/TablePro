import Foundation
import Network
import os

actor HttpConnectionContext {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.HttpServer")

    nonisolated let id: UUID
    private let connection: NWConnection
    private var receiveBuffer = Data()
    private var requestComplete = false
    private var cancelled = false
    private var sseActive = false
    private var origin: String?

    init(id: UUID, connection: NWConnection) {
        self.id = id
        self.connection = connection
    }

    func setOrigin(_ value: String?) {
        origin = value
    }

    private func corsHeaders() -> [(String, String)] {
        MCPCorsHeaders.headers(forOrigin: origin)
    }

    func start(
        onData: @escaping @Sendable (Data) async -> Void,
        onClosed: @escaping @Sendable () async -> Void
    ) {
        let nwConnection = connection
        nwConnection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Task { await self.beginReading(onData: onData, onClosed: onClosed) }
            case .failed:
                Task { await self.handleClosed(onClosed: onClosed) }
            case .cancelled:
                Task { await self.handleClosed(onClosed: onClosed) }
            default:
                break
            }
        }
        nwConnection.start(queue: .global(qos: .userInitiated))
    }

    private func beginReading(
        onData: @escaping @Sendable (Data) async -> Void,
        onClosed: @escaping @Sendable () async -> Void
    ) {
        scheduleReceive(onData: onData, onClosed: onClosed)
    }

    private func scheduleReceive(
        onData: @escaping @Sendable (Data) async -> Void,
        onClosed: @escaping @Sendable () async -> Void
    ) {
        if cancelled || requestComplete { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            Task {
                await self.handleReceive(
                    content: content,
                    isComplete: isComplete,
                    error: error,
                    onData: onData,
                    onClosed: onClosed
                )
            }
        }
    }

    private func handleReceive(
        content: Data?,
        isComplete: Bool,
        error: NWError?,
        onData: @escaping @Sendable (Data) async -> Void,
        onClosed: @escaping @Sendable () async -> Void
    ) async {
        if let error {
            Self.logger.debug("Receive error: \(error.localizedDescription, privacy: .public)")
            cancel()
            await onClosed()
            return
        }

        if let content {
            receiveBuffer.append(content)
            await onData(receiveBuffer)
        }

        if isComplete {
            cancel()
            await onClosed()
            return
        }

        if !requestComplete, !cancelled {
            scheduleReceive(onData: onData, onClosed: onClosed)
        }
    }

    private func handleClosed(onClosed: @escaping @Sendable () async -> Void) async {
        if !cancelled {
            cancelled = true
        }
        await onClosed()
    }

    func markRequestComplete() {
        requestComplete = true
    }

    func clientAddress() -> MCPClientAddress {
        guard let endpoint = connection.currentPath?.remoteEndpoint,
              case .hostPort(let host, _) = endpoint else {
            return .loopback
        }
        let hostString = "\(host)"
        if hostString == "127.0.0.1" || hostString == "::1" || hostString.lowercased() == "localhost" {
            return .loopback
        }
        return .remote(hostString)
    }

    func writeJsonResponse(
        data: Data,
        status: HttpStatus,
        sessionId: MCPSessionId?,
        extraHeaders: [(String, String)]
    ) async {
        if cancelled { return }
        var headers: [(String, String)] = [
            ("Content-Type", "application/json"),
            ("Connection", "close")
        ]
        if let sessionId {
            headers.append(("Mcp-Session-Id", sessionId.rawValue))
        }
        headers.append(contentsOf: extraHeaders)
        headers.append(contentsOf: self.corsHeaders())
        let head = HttpResponseHead(status: status, headers: HttpHeaders(headers))
        let payload = HttpResponseEncoder.encode(head, body: data)
        await send(payload)
    }

    func writePlainJsonResponse(status: HttpStatus, body: Data) async {
        if cancelled { return }
        var headers: [(String, String)] = [
            ("Content-Type", "application/json"),
            ("Connection", "close")
        ]
        headers.append(contentsOf: self.corsHeaders())
        let head = HttpResponseHead(status: status, headers: HttpHeaders(headers))
        let payload = HttpResponseEncoder.encode(head, body: body)
        await send(payload)
    }

    func writePlainJsonError(status: HttpStatus, message: String) async {
        struct ErrorBody: Encodable { let error: String }
        let payload = (try? JSONEncoder().encode(ErrorBody(error: message))) ?? Data()
        await writePlainJsonResponse(status: status, body: payload)
    }

    func writeOptions204() async {
        if cancelled { return }
        var headers: [(String, String)] = [("Connection", "close")]
        headers.append(contentsOf: self.corsHeaders())
        let head = HttpResponseHead(status: .noContent, headers: HttpHeaders(headers))
        let payload = HttpResponseEncoder.encode(head, body: nil)
        await send(payload)
    }

    func writeNoContent() async {
        if cancelled { return }
        var headers: [(String, String)] = [("Connection", "close")]
        headers.append(contentsOf: self.corsHeaders())
        let head = HttpResponseHead(status: .noContent, headers: HttpHeaders(headers))
        let payload = HttpResponseEncoder.encode(head, body: nil)
        await send(payload)
    }

    func writeAccepted() async {
        if cancelled { return }
        var headers: [(String, String)] = [("Connection", "close")]
        headers.append(contentsOf: self.corsHeaders())
        let head = HttpResponseHead(status: .accepted, headers: HttpHeaders(headers))
        let payload = HttpResponseEncoder.encode(head, body: nil)
        await send(payload)
    }

    func writeSseStreamHeaders(sessionId: MCPSessionId) async {
        if cancelled { return }
        sseActive = true
        var headers: [(String, String)] = [
            ("Content-Type", "text/event-stream"),
            ("Cache-Control", "no-cache"),
            ("Connection", "keep-alive"),
            ("Mcp-Session-Id", sessionId.rawValue)
        ]
        headers.append(contentsOf: self.corsHeaders())
        let head = HttpResponseHead(status: .ok, headers: HttpHeaders(headers))
        let payload = HttpResponseEncoder.encode(head, body: nil)
        await send(payload)
    }

    func writeSseFrame(_ frame: SseFrame) async {
        if cancelled { return }
        let data = SseEncoder.encode(frame)
        await send(data)
    }

    func writeRaw(_ data: Data) async {
        if cancelled { return }
        await send(data)
    }

    func cancel() {
        if cancelled { return }
        cancelled = true
        connection.cancel()
    }

    func isSseActive() -> Bool {
        sseActive
    }

    func isCancelled() -> Bool {
        cancelled
    }

    private func send(_ data: Data) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    Self.logger.debug("Send error: \(error.localizedDescription, privacy: .public)")
                }
                continuation.resume()
            })
        }
    }
}
