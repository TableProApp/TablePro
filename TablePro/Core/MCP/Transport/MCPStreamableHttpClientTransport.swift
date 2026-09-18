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

    private static let namedMethods: Set<String> = ["tools/call", "resources/read", "prompts/get"]
    private static let unavailableMessage =
        "TablePro's MCP server is not reachable. Make sure TablePro is running and the MCP server is enabled in Settings > Integrations."

    private let configuration: MCPStreamableHttpClientConfiguration
    private let credentialsProvider: any MCPUpstreamCredentialsProviding
    private let urlSession: URLSession
    private let errorLogger: (any MCPBridgeLogger)?

    private var isClosed = false
    private var pending: [UUID: Task<Void, Never>] = [:]

    public init(
        configuration: MCPStreamableHttpClientConfiguration = MCPStreamableHttpClientConfiguration(),
        credentialsProvider: any MCPUpstreamCredentialsProviding,
        urlSession: URLSession? = nil,
        errorLogger: (any MCPBridgeLogger)? = nil
    ) {
        self.configuration = configuration
        self.credentialsProvider = credentialsProvider
        self.errorLogger = errorLogger

        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        self.inbound = stream
        self.continuation = continuation

        if let urlSession {
            self.urlSession = urlSession
        } else {
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.timeoutIntervalForRequest =
                TimeInterval(configuration.requestTimeout.components.seconds)
            sessionConfiguration.waitsForConnectivity = false
            sessionConfiguration.httpMaximumConnectionsPerHost = 16
            self.urlSession = URLSession(configuration: sessionConfiguration)
        }
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
        urlSession.invalidateAndCancel()
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

    private func recover(from error: MCPTransportError, frame: MCPUpstreamFrame) async {
        guard !isClosed, !Task.isCancelled else { return }
        guard case .authentication = error else {
            emitTransportFailure(error, frame: frame)
            return
        }

        do {
            _ = try await credentialsProvider.refreshCredentials()
            errorLogger?.log(.info, "Re-acquired the MCP handshake after upstream rejected the bridge token")
            try await perform(frame, allowCredentialRefresh: false)
        } catch {
            emitTransportFailure(error, frame: frame)
        }
    }

    private func perform(_ frame: MCPUpstreamFrame, allowCredentialRefresh: Bool) async throws {
        let credentials = await credentialsProvider.currentCredentials()
        let exchange = MCPUpstreamExchange()
        let task = urlSession.dataTask(with: makeRequest(credentials: credentials, frame: frame))
        task.delegate = exchange
        task.resume()
        defer { task.cancel() }

        let head: HTTPURLResponse
        do {
            head = try await exchange.awaitHead()
        } catch {
            throw Self.mapRequestFailure(error)
        }

        let status = head.statusCode
        if status == 401, allowCredentialRefresh {
            throw MCPTransportError.authentication(
                httpStatus: status,
                message: "Upstream rejected the bridge token"
            )
        }

        let contentType = head.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""

        guard (200..<300).contains(status) else {
            let body = try await collect(exchange.body)
            emitHttpFailure(status: status, head: head, body: body, frame: frame)
            return
        }

        if contentType.contains("text/event-stream") {
            try await forwardEventStream(exchange.body)
            return
        }

        emit(try await collect(exchange.body))
    }

    private func makeRequest(credentials: MCPUpstreamCredentials, frame: MCPUpstreamFrame) -> URLRequest {
        var request = URLRequest(url: credentials.endpoint)
        request.httpMethod = "POST"
        request.httpBody = frame.body
        request.timeoutInterval = TimeInterval(configuration.requestTimeout.components.seconds)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(credentials.bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(MCPProtocolVersion.latest.rawValue, forHTTPHeaderField: "MCP-Protocol-Version")

        guard let method = frame.method else {
            return request
        }
        request.setValue(method, forHTTPHeaderField: "Mcp-Method")

        guard Self.namedMethods.contains(method), let name = frame.name else {
            return request
        }
        request.setValue(MCPBase64Sentinel.encodeIfNeeded(name), forHTTPHeaderField: "Mcp-Name")
        return request
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
        head: HTTPURLResponse,
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

        let allow = head.value(forHTTPHeaderField: "Allow") ?? "POST, OPTIONS"
        let protocolError = Self.protocolError(status: status, body: body, frame: frame, allow: allow)
        emitError(protocolError.toJsonRpcErrorResponse(id: requestId))
    }

    private func emitTransportFailure(_ error: Error, frame: MCPUpstreamFrame) {
        if Task.isCancelled || isClosed {
            return
        }
        errorLogger?.log(.error, "Upstream request failed: \(error)")

        guard let requestId = frame.requestId else { return }

        if case MCPTransportError.unreachable = error {
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

    private static func mapRequestFailure(_ error: Error) -> MCPTransportError {
        guard let urlError = error as? URLError else {
            return .readFailed(detail: String(describing: error))
        }
        switch urlError.code {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
            return .unreachable(detail: urlError.localizedDescription)
        case .timedOut:
            return .timeout
        default:
            return .readFailed(detail: urlError.localizedDescription)
        }
    }
}

private final class MCPUpstreamExchange: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let body: AsyncThrowingStream<Data, Error>

    private let bodyContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var head: HTTPURLResponse?
    private var failure: Error?
    private var headContinuation: CheckedContinuation<HTTPURLResponse, Error>?

    override init() {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        body = stream
        bodyContinuation = continuation
        super.init()
    }

    func awaitHead() async throws -> HTTPURLResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let head {
                lock.unlock()
                continuation.resume(returning: head)
                return
            }
            if let failure {
                lock.unlock()
                continuation.resume(throwing: failure)
                return
            }
            headContinuation = continuation
            lock.unlock()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse else {
            resolveHead(.failure(MCPTransportError.readFailed(detail: "non-HTTP response")))
            completionHandler(.cancel)
            return
        }
        resolveHead(.success(httpResponse))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        bodyContinuation.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            resolveHead(.failure(error))
            bodyContinuation.finish(throwing: error)
            return
        }
        resolveHead(.failure(MCPTransportError.readFailed(detail: "response ended before its head arrived")))
        bodyContinuation.finish()
    }

    private func resolveHead(_ result: Result<HTTPURLResponse, Error>) {
        lock.lock()
        guard head == nil, failure == nil else {
            lock.unlock()
            return
        }
        switch result {
        case .success(let response):
            head = response
        case .failure(let error):
            failure = error
        }
        let waiting = headContinuation
        headContinuation = nil
        lock.unlock()
        waiting?.resume(with: result)
    }
}
