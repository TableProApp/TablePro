import Foundation

public struct MCPStreamableHttpClientConfiguration: Sendable {
    public static let defaultRequestTimeout: Duration = .seconds(360)

    public let requestTimeout: Duration

    public init(requestTimeout: Duration = MCPStreamableHttpClientConfiguration.defaultRequestTimeout) {
        self.requestTimeout = requestTimeout
    }
}

public struct MCPUpstreamFrame: Sendable, Equatable {
    public let body: Data
    public let method: String?
    public let name: String?
    public let requestId: JsonRpcId?

    public init(body: Data, method: String? = nil, name: String? = nil, requestId: JsonRpcId? = nil) {
        self.body = body
        self.method = method
        self.name = name
        self.requestId = requestId
    }
}

public actor MCPStreamableHttpClientTransport {
    nonisolated public let inbound: AsyncThrowingStream<Data, Error>
    nonisolated private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    private static let mcpPath = "/mcp"
    private static let namedMethods: Set<String> = ["tools/call", "resources/read", "prompts/get"]
    private static let unavailableMessage =
        "TablePro's MCP server is not reachable. Make sure TablePro is running and the MCP server is enabled in Settings > MCP."

    private let configuration: MCPStreamableHttpClientConfiguration
    private let credentialsProvider: any MCPUpstreamCredentialsProviding
    private let errorLogger: (any MCPBridgeLogger)?

    private var isClosed = false
    private var pending: [UUID: Task<Void, Never>] = [:]

    public init(
        configuration: MCPStreamableHttpClientConfiguration = MCPStreamableHttpClientConfiguration(),
        credentialsProvider: any MCPUpstreamCredentialsProviding,
        errorLogger: (any MCPBridgeLogger)? = nil
    ) {
        self.configuration = configuration
        self.credentialsProvider = credentialsProvider
        self.errorLogger = errorLogger

        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        self.inbound = stream
        self.continuation = continuation
    }

    public func send(_ frame: MCPUpstreamFrame) async throws {
        if isClosed {
            throw MCPTransportError.closed
        }
        let key = UUID()
        pending[key] = Task { [weak self] in
            await self?.dispatch(frame)
            await self?.forget(key)
        }
    }

    public func close() async {
        if isClosed {
            return
        }
        isClosed = true

        let running = Array(pending.values)
        pending.removeAll()
        for task in running {
            task.cancel()
        }
        continuation.finish()
    }

    private func forget(_ key: UUID) {
        pending.removeValue(forKey: key)
    }

    private func dispatch(_ frame: MCPUpstreamFrame) async {
        do {
            try await perform(frame, allowCredentialRefresh: true)
        } catch let error as MCPTransportError {
            await recover(from: error, frame: frame)
        } catch {
            emitTransportFailure(error, frame: frame)
        }
    }

    // The app may have restarted: resend only after the provider re-acquires and verifies the listener.
    private func recover(from failure: MCPTransportError, frame: MCPUpstreamFrame) async {
        guard !isClosed, !Task.isCancelled else { return }
        switch failure {
        case .authentication, .unreachable:
            break
        default:
            emitTransportFailure(failure, frame: frame)
            return
        }

        do {
            _ = try await credentialsProvider.refreshCredentials()
        } catch {
            errorLogger?.log(.error, "Re-acquiring the MCP handshake failed: \(error)")
            emitTransportFailure(error, frame: frame, original: failure)
            return
        }
        guard !isClosed, !Task.isCancelled else { return }
        errorLogger?.log(.info, "Re-acquired the MCP handshake after \(failure)")
        do {
            try await perform(frame, allowCredentialRefresh: false)
        } catch {
            emitTransportFailure(error, frame: frame)
        }
    }

    private func perform(_ frame: MCPUpstreamFrame, allowCredentialRefresh: Bool) async throws {
        let credentials = await credentialsProvider.currentCredentials()
        let request = makeRequest(credentials: credentials, frame: frame)

        let response: MCPSocketHttpResponse
        do {
            response = try await MCPUnixSocketHttpClient.send(
                request,
                socketPath: credentials.socketPath,
                idleTimeout: configuration.requestTimeout
            )
        } catch {
            throw Self.mapRequestFailure(error)
        }

        let status = response.status
        if status == 401, allowCredentialRefresh {
            throw MCPTransportError.authentication(
                httpStatus: status,
                message: "Upstream rejected the bridge token"
            )
        }

        let contentType = response.headers.value(for: "Content-Type")?.lowercased() ?? ""

        guard (200..<300).contains(status) else {
            let body = try await collect(response.body)
            emitHttpFailure(status: status, headers: response.headers, body: body, frame: frame)
            return
        }

        if contentType.contains("text/event-stream") {
            try await forwardEventStream(response.body)
            return
        }

        emit(try await collect(response.body))
    }

    private func makeRequest(credentials: MCPUpstreamCredentials, frame: MCPUpstreamFrame) -> MCPSocketHttpRequest {
        var headers: [(String, String)] = [
            ("Content-Type", "application/json"),
            ("Accept", "application/json, text/event-stream"),
            ("Authorization", "Bearer \(credentials.bearerToken)"),
            ("MCP-Protocol-Version", MCPProtocolVersion.latest.rawValue)
        ]
        if let method = frame.method {
            headers.append(("Mcp-Method", method))
            if Self.namedMethods.contains(method), let name = frame.name {
                headers.append(("Mcp-Name", MCPBase64Sentinel.encodeIfNeeded(name)))
            }
        }
        return MCPSocketHttpRequest(path: Self.mcpPath, headers: headers, body: frame.body)
    }

    private func forwardEventStream(_ body: AsyncThrowingStream<Data, Error>) async throws {
        let decoder = SseDecoder()
        for try await chunk in body {
            if Task.isCancelled {
                return
            }
            for frame in await decoder.feed(chunk) {
                guard let payload = frame.data.data(using: .utf8) else { continue }
                emit(payload)
            }
        }
    }

    private func collect(_ body: AsyncThrowingStream<Data, Error>) async throws -> Data {
        var data = Data()
        for try await chunk in body {
            if Task.isCancelled {
                return data
            }
            data.append(chunk)
        }
        return data
    }

    private func emit(_ payload: Data) {
        guard !payload.isEmpty else { return }
        continuation.yield(Self.singleLine(payload))
    }

    private func emitHttpFailure(
        status: Int,
        headers: HttpHeaders,
        body: Data,
        frame: MCPUpstreamFrame
    ) {
        guard let requestId = frame.requestId else {
            errorLogger?.log(.warning, "HTTP \(status) for a notification, nothing to answer")
            return
        }

        if !body.isEmpty, Self.isJsonRpcResponse(body) {
            emit(body)
            return
        }

        let allow = headers.value(for: "Allow") ?? "POST, OPTIONS"
        let protocolError = Self.protocolError(status: status, body: body, frame: frame, allow: allow)
        emitError(protocolError.toJsonRpcErrorResponse(id: requestId))
    }

    private func emitTransportFailure(_ error: Error, frame: MCPUpstreamFrame, original: Error? = nil) {
        if Task.isCancelled || isClosed {
            return
        }
        errorLogger?.log(.error, "Upstream request failed: \(error)")

        guard let requestId = frame.requestId else { return }

        if case MCPTransportError.unreachable = original ?? error {
            emitError(
                JsonRpcErrorResponse(
                    id: requestId,
                    error: JsonRpcError(code: JsonRpcErrorCode.serverError, message: Self.unavailableMessage)
                )
            )
            return
        }
        emitError(
            MCPProtocolError.internalError(detail: String(describing: error))
                .toJsonRpcErrorResponse(id: requestId)
        )
    }

    private func emitError(_ response: JsonRpcErrorResponse) {
        guard let encoded = try? JsonRpcCodec.encode(.errorResponse(response)) else { return }
        emit(encoded)
    }

    private static func singleLine(_ payload: Data) -> Data {
        guard payload.contains(0x0A) || payload.contains(0x0D) else { return payload }
        return Data(payload.filter { $0 != 0x0A && $0 != 0x0D })
    }

    private static func isJsonRpcResponse(_ body: Data) -> Bool {
        guard let message = try? JsonRpcCodec.decode(body) else { return false }
        switch message {
        case .successResponse, .errorResponse:
            return true
        case .request, .notification:
            return false
        }
    }

    private static func protocolError(
        status: Int,
        body: Data,
        frame: MCPUpstreamFrame,
        allow: String
    ) -> MCPProtocolError {
        let detail = String(data: body, encoding: .utf8) ?? "HTTP \(status)"
        switch status {
        case 400:
            return .invalidRequest(detail: detail)
        case 401:
            return .unauthenticated()
        case 403:
            return .forbidden(reason: detail)
        case 404:
            return .methodNotFound(method: frame.method ?? "unknown")
        case 405:
            return .methodNotAllowed(allow: allow)
        case 406:
            return .notAcceptable()
        case 413:
            return .payloadTooLarge()
        case 429:
            return .rateLimited()
        case 503:
            return .serviceUnavailable()
        default:
            return .internalError(detail: detail)
        }
    }

    private static func mapRequestFailure(_ error: Error) -> Error {
        guard let failure = error as? MCPSocketHttpError else {
            return error
        }
        switch failure {
        case .connectFailed(let detail), .invalidSocketPath(let detail):
            return MCPTransportError.unreachable(detail: detail)
        case .timedOut:
            return MCPTransportError.timeout
        case .invalidHeader(let name):
            return MCPTransportError.malformedFrame(detail: "\(name) cannot be sent as an HTTP header")
        case .connectionClosed(let detail), .malformedResponse(let detail):
            return MCPTransportError.readFailed(detail: detail)
        }
    }
}
