import Foundation
import Network
import os

actor HttpConnectionContext {
    typealias RequestHandler = @Sendable (HttpParsedRequest) async -> Void
    typealias ClosedHandler = @Sendable () async -> Void

    private enum ReceiveOutcome: Sendable {
        case chunk(Data?, isComplete: Bool)
        case failure(String)
    }

    private enum Mode: Sendable {
        case serve
        case reject
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.HttpConnection")
    private static let receiveChunkSize = 65_536
    private static let rejectionGrace: Duration = .seconds(2)

    nonisolated let id: UUID

    private let connection: NWConnection
    private let limits: MCPHttpServerLimits

    private var parser: HttpRequestStreamParser
    private var requestHandler: RequestHandler?
    private var closedHandler: ClosedHandler?

    private var mode: Mode = .serve
    private var closed = false
    private var notifiedClosed = false
    private var started = false
    private var responseInProgress = false
    private var headWritten = false
    private var keepAlive = true
    private var origin: String?
    private var sseWriter: MCPSseWriter?
    private var readTask: Task<Void, Never>?
    private var handlerTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?

    init(id: UUID, connection: NWConnection, limits: MCPHttpServerLimits) {
        self.id = id
        self.connection = connection
        self.limits = limits
        parser = HttpRequestStreamParser(limits: limits.parserLimits)
    }

    func start(onRequest: @escaping RequestHandler, onClosed: @escaping ClosedHandler) {
        guard !started else { return }
        started = true
        requestHandler = onRequest
        closedHandler = onClosed
        observeState()
        connection.start(queue: .global(qos: .userInitiated))
    }

    func rejectOverCapacity() {
        guard !started else { return }
        started = true
        mode = .reject
        observeState()
        connection.start(queue: .global(qos: .userInitiated))
        Task {
            try? await Task.sleep(for: Self.rejectionGrace)
            self.closeAfterRejection()
        }
    }

    func isClosed() -> Bool {
        closed
    }

    func isStreaming() -> Bool {
        sseWriter != nil
    }

    func setOrigin(_ value: String?) {
        origin = value
    }

    func clientAddress() -> MCPClientAddress {
        guard let endpoint = connection.currentPath?.remoteEndpoint else {
            return .remote("unknown")
        }
        guard case .hostPort(let host, _) = endpoint else {
            return .remote(String(describing: endpoint))
        }
        switch host {
        case .ipv4(let address):
            return address.isLoopback ? .loopback : .remote(String(describing: address))
        case .ipv6(let address):
            return address.isLoopback ? .loopback : .remote(String(describing: address))
        case .name(let name, _):
            return name.lowercased() == "localhost" ? .loopback : .remote(name)
        @unknown default:
            return .remote("unknown")
        }
    }

    private func observeState() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Task { await self.handleReady() }
            case .failed(let error):
                Task { await self.handleTransportFailure(error.localizedDescription) }
            case .cancelled:
                Task { await self.handlePeerClosed() }
            default:
                break
            }
        }
    }

    private func handleReady() async {
        switch mode {
        case .serve:
            beginReading()
        case .reject:
            await writeCapacityRejection()
        }
    }

    private func beginReading() {
        guard !closed, readTask == nil, requestHandler != nil else { return }
        armIdleTimeout()
        readTask = Task { [weak self] in
            await self?.runReadLoop()
        }
    }

    private func runReadLoop() async {
        while !closed {
            let outcome = await receiveChunk()
            switch outcome {
            case .failure(let reason):
                Self.logger.debug("Receive failed: \(reason, privacy: .public)")
                await handlePeerClosed()
                return
            case .chunk(let content, let isComplete):
                if let content, !content.isEmpty {
                    do {
                        try ingest(content)
                    } catch {
                        await respondToParseFailure(error)
                        return
                    }
                }
                if isComplete {
                    await handlePeerClosed()
                    return
                }
            }
        }
    }

    private func receiveChunk() async -> ReceiveOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<ReceiveOutcome, Never>) in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: Self.receiveChunkSize
            ) { content, _, isComplete, error in
                if let error {
                    continuation.resume(returning: .failure(error.localizedDescription))
                    return
                }
                continuation.resume(returning: .chunk(content, isComplete: isComplete))
            }
        }
    }

    private func ingest(_ data: Data) throws {
        parser.append(data)
        let bufferCeiling = limits.maxRequestBodyBytes + limits.maxHeaderBytes
        guard parser.pendingByteCount <= bufferCeiling else {
            throw HttpRequestParseError.bodyTooLarge(limit: bufferCeiling, actual: parser.pendingByteCount)
        }
        try dispatchNextRequest()
        refreshIdleTimeout()
    }

    private func dispatchNextRequest() throws {
        guard !closed, !responseInProgress, let handler = requestHandler else { return }
        guard let request = try parser.next() else { return }
        responseInProgress = true
        headWritten = false
        keepAlive = request.head.wantsKeepAlive
        origin = request.head.headers.value(for: "Origin")
        cancelIdleTimeout()
        handlerTask = Task { await handler(request) }
    }

    private func refreshIdleTimeout() {
        guard !responseInProgress else {
            cancelIdleTimeout()
            return
        }
        guard parser.isBetweenRequests else { return }
        armIdleTimeout()
    }

    private func armIdleTimeout() {
        idleTask?.cancel()
        let timeout = limits.connectionTimeout
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.handleIdleTimeout()
        }
    }

    private func cancelIdleTimeout() {
        idleTask?.cancel()
        idleTask = nil
    }

    private func handleIdleTimeout() async {
        guard !closed, !responseInProgress else { return }
        if parser.pendingByteCount > 0 {
            keepAlive = false
            await writeResponse(status: .requestTimeout, headers: [], body: nil)
        }
        Self.logger.debug("Closing idle connection \(self.id, privacy: .public)")
        close()
    }

    private func handlePeerClosed() async {
        markClosed()
        await notifyClosed()
    }

    private func notifyClosed() async {
        guard !notifiedClosed else { return }
        notifiedClosed = true
        let handler = closedHandler
        closedHandler = nil
        requestHandler = nil
        await handler?()
    }

    private func markClosed() {
        guard !closed else { return }
        closed = true
        cancelIdleTimeout()
        readTask?.cancel()
        readTask = nil
        stopSseWriter()
        handlerTask?.cancel()
        connection.cancel()
    }

    private func handleTransportFailure(_ reason: String) async {
        Self.logger.debug("Connection failed: \(reason, privacy: .public)")
        await handlePeerClosed()
    }

    func completeResponse() async {
        guard responseInProgress else { return }
        responseInProgress = false
        headWritten = false
        if sseWriter != nil {
            stopSseWriter()
            close()
            return
        }
        guard keepAlive, !closed else {
            close()
            return
        }
        armIdleTimeout()
        do {
            try dispatchNextRequest()
        } catch {
            await respondToParseFailure(error)
        }
    }

    func writeJsonResponse(data: Data, status: HttpStatus, extraHeaders: [(String, String)]) async {
        var headers: [(String, String)] = [("Content-Type", "application/json")]
        headers.append(contentsOf: extraHeaders)
        await writeResponse(status: status, headers: headers, body: data)
    }

    func writeAccepted() async {
        await writeResponse(status: .accepted, headers: [], body: Data())
    }

    func writeNoContent() async {
        await writeResponse(status: .noContent, headers: [], body: nil)
    }

    func writeOptionsPreflight() async {
        await writeResponse(status: .noContent, headers: [("Allow", "POST, OPTIONS")], body: nil)
    }

    func writeMethodNotAllowed() async {
        let payload = Self.plainErrorBody(
            error: "method_not_allowed",
            description: String(localized: "This HTTP method is not supported.")
        )
        await writeJsonResponse(
            data: payload,
            status: .methodNotAllowed,
            extraHeaders: [("Allow", "POST, OPTIONS")]
        )
    }

    func writePlainJsonResponse(status: HttpStatus, body: Data, extraHeaders: [(String, String)] = []) async {
        await writeJsonResponse(data: body, status: status, extraHeaders: extraHeaders)
    }

    func writePlainJsonError(status: HttpStatus, message: String, extraHeaders: [(String, String)] = []) async {
        struct ErrorBody: Encodable { let error: String }
        let payload = (try? JSONEncoder().encode(ErrorBody(error: message))) ?? Data()
        await writeJsonResponse(data: payload, status: status, extraHeaders: extraHeaders)
    }

    func writePlainJsonError(
        status: HttpStatus,
        error: String,
        errorDescription: String,
        extraHeaders: [(String, String)] = []
    ) async {
        let payload = Self.plainErrorBody(error: error, description: errorDescription)
        await writeJsonResponse(data: payload, status: status, extraHeaders: extraHeaders)
    }

    func beginSseStream() async {
        guard !closed, !headWritten else { return }
        headWritten = true
        keepAlive = false
        var headers: [(String, String)] = [
            ("Content-Type", "text/event-stream"),
            ("Cache-Control", "no-cache, no-store"),
            ("X-Accel-Buffering", "no"),
            ("Connection", "close")
        ]
        headers.append(contentsOf: MCPCorsHeaders.headers(forOrigin: origin))
        let head = HttpResponseHead(status: .ok, headers: HttpHeaders(headers))
        await send(HttpResponseEncoder.encodeStreamHead(head))
        guard !closed else { return }
        let writer = MCPSseWriter(
            emit: { [weak self] data in await self?.writeRaw(data) },
            isAlive: { [weak self] in await self?.isOpen() ?? false }
        )
        sseWriter = writer
        await writer.start()
    }

    func writeSseFrame(_ frame: SseFrame) async {
        guard let sseWriter else { return }
        await sseWriter.writeFrame(frame)
    }

    func writeSseComment(_ text: String) async {
        guard let sseWriter else { return }
        await sseWriter.writeComment(text)
    }

    func writeRaw(_ data: Data) async {
        await send(data)
    }

    func close() {
        markClosed()
    }

    private func closeAfterRejection() {
        markClosed()
    }

    private func stopSseWriter() {
        guard let writer = sseWriter else { return }
        sseWriter = nil
        Task { await writer.stop() }
    }

    private func isOpen() -> Bool {
        !closed
    }

    private func writeResponse(status: HttpStatus, headers: [(String, String)], body: Data?) async {
        guard !closed, !headWritten else { return }
        headWritten = true
        var all = headers
        all.append(("Connection", keepAlive ? "keep-alive" : "close"))
        all.append(contentsOf: MCPCorsHeaders.headers(forOrigin: origin))
        let head = HttpResponseHead(status: status, headers: HttpHeaders(all))
        await send(HttpResponseEncoder.encode(head, body: body))
    }

    private func writeCapacityRejection() async {
        keepAlive = false
        let payload = Self.plainErrorBody(
            error: "too_many_connections",
            description: String(localized: "TablePro's MCP server has too many open connections.")
        )
        await writeJsonResponse(
            data: payload,
            status: .serviceUnavailable,
            extraHeaders: [("Retry-After", "1")]
        )
        close()
    }

    private func respondToParseFailure(_ error: Error) async {
        let failure = error as? HttpRequestParseError
        let protocolError: MCPProtocolError
        switch failure {
        case .headerTooLarge:
            protocolError = MCPProtocolError(
                code: JsonRpcErrorCode.tooLarge,
                message: "Request header fields too large",
                httpStatus: .requestHeaderFieldsTooLarge
            )
        case .bodyTooLarge:
            protocolError = .payloadTooLarge()
        case .unsupportedTransferEncoding(let coding):
            protocolError = MCPProtocolError(
                code: JsonRpcErrorCode.invalidRequest,
                message: "Unsupported Transfer-Encoding: \(coding)",
                httpStatus: .notImplemented
            )
        case .missingHostHeader:
            protocolError = .invalidRequest(detail: "Host header is required")
        default:
            protocolError = .invalidRequest(detail: "Malformed HTTP request")
        }
        keepAlive = false
        let envelope = protocolError.toJsonRpcErrorResponse(id: nil)
        let data = (try? JSONEncoder().encode(envelope)) ?? Data()
        await writeJsonResponse(
            data: data,
            status: protocolError.httpStatus,
            extraHeaders: protocolError.extraHeaders
        )
        close()
    }

    private func send(_ data: Data) async {
        guard !closed else { return }
        let failed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(returning: error != nil)
            })
        }
        guard failed else { return }
        Self.logger.debug("Send failed on connection \(self.id, privacy: .public); closing")
        close()
    }

    private static func plainErrorBody(error: String, description: String) -> Data {
        struct ErrorBody: Encodable {
            let error: String
            let errorDescription: String
            enum CodingKeys: String, CodingKey {
                case error
                case errorDescription = "error_description"
            }
        }
        return (try? JSONEncoder().encode(ErrorBody(error: error, errorDescription: description))) ?? Data()
    }
}
