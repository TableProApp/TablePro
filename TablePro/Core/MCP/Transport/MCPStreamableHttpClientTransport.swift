import CryptoKit
import Foundation
import Security

public struct MCPStreamableHttpClientConfiguration: Sendable {
    public let requestTimeout: Duration
    public let serverInitiatedStream: Bool
    public let keepaliveInterval: Duration?

    public init(
        requestTimeout: Duration = .seconds(60),
        serverInitiatedStream: Bool = false,
        keepaliveInterval: Duration? = .seconds(300)
    ) {
        self.requestTimeout = requestTimeout
        self.serverInitiatedStream = serverInitiatedStream
        self.keepaliveInterval = keepaliveInterval
    }
}

public enum MCPUpstreamRecoveryError: Error, Sendable, Equatable {
    case noCachedInitialize
    case reinitializeFailed(status: Int)
    case initializedNotificationFailed(status: Int)
}

enum MCPUpstreamRecoveryReason: Sendable, Equatable {
    case sessionExpired
    case credentialsRejected
}

public actor MCPStreamableHttpClientTransport: MCPMessageTransport {
    nonisolated public let inbound: AsyncThrowingStream<JsonRpcMessage, Error>
    nonisolated private let continuation: AsyncThrowingStream<JsonRpcMessage, Error>.Continuation

    private static let initializeMethod = "initialize"
    private static let initializedNotificationMethod = "notifications/initialized"
    private static let pingMethod = "ping"
    private static let recoveryKey = "upstream"
    private static let sessionTerminationTimeout: TimeInterval = 2
    private static let unavailableMessage =
        "TablePro's MCP server is not reachable. Make sure TablePro is running and the MCP server is enabled in Settings > Integrations."

    private let configuration: MCPStreamableHttpClientConfiguration
    private let credentialsProvider: any MCPUpstreamCredentialsProviding
    private let clock: any MCPClock
    private let urlSession: URLSession
    private let errorLogger: (any MCPBridgeLogger)?
    private let recoveryCoordinator = OnceTask<String, Void>()

    private var sessionId: String?
    private var sessionGeneration = 0
    private var cachedInitializeRequest: JsonRpcRequest?
    private var cachedInitializedNotification: JsonRpcNotification?
    private var negotiatedProtocolVersion: String?
    private var isClosed = false
    private var serverInitiatedStreamOpen = false
    private var keepaliveStarted = false
    private var tasks: [Task<Void, Never>] = []

    public init(
        configuration: MCPStreamableHttpClientConfiguration,
        credentialsProvider: any MCPUpstreamCredentialsProviding,
        clock: any MCPClock = MCPSystemClock(),
        urlSession: URLSession? = nil,
        errorLogger: (any MCPBridgeLogger)? = nil
    ) {
        self.configuration = configuration
        self.credentialsProvider = credentialsProvider
        self.clock = clock
        self.errorLogger = errorLogger

        let (stream, continuation) = AsyncThrowingStream<JsonRpcMessage, Error>.makeStream()
        self.inbound = stream
        self.continuation = continuation

        if let urlSession {
            self.urlSession = urlSession
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = TimeInterval(configuration.requestTimeout.components.seconds)
            config.timeoutIntervalForResource = TimeInterval(configuration.requestTimeout.components.seconds)
            let delegate = CertificatePinningDelegate(
                expectedFingerprint: { await credentialsProvider.currentCredentials().tlsCertFingerprint },
                errorLogger: errorLogger
            )
            self.urlSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        }
    }

    public func send(_ message: JsonRpcMessage) async throws {
        if isClosed {
            throw MCPTransportError.closed
        }

        cacheHandshakeState(from: message)

        let body: Data
        do {
            body = try JsonRpcCodec.encode(message)
        } catch {
            throw MCPTransportError.writeFailed(detail: String(describing: error))
        }

        startKeepaliveIfNeeded()

        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.dispatch(message: message, body: body)
        }
        trackTask(task)
    }

    public func openSseStream() async throws {
        if isClosed {
            throw MCPTransportError.closed
        }
        if serverInitiatedStreamOpen {
            return
        }
        serverInitiatedStreamOpen = true

        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.runServerInitiatedStream()
        }
        trackTask(task)
    }

    public func close() async {
        if isClosed {
            return
        }
        isClosed = true

        await terminateUpstreamSession()

        let pending = tasks
        tasks.removeAll()
        for task in pending {
            task.cancel()
        }
        urlSession.invalidateAndCancel()
        continuation.finish()
    }

    private func trackTask(_ task: Task<Void, Never>) {
        tasks.removeAll { $0.isCancelled }
        tasks.append(task)
    }

    private func cacheHandshakeState(from message: JsonRpcMessage) {
        switch message {
        case .request(let request) where request.method == Self.initializeMethod:
            cachedInitializeRequest = request
        case .notification(let notification) where notification.method == Self.initializedNotificationMethod:
            cachedInitializedNotification = notification
        default:
            break
        }
    }

    private func dispatch(message: JsonRpcMessage, body: Data) async {
        let generation = sessionGeneration
        do {
            try await performRequest(message: message, body: body, allowRecovery: true)
        } catch let error as MCPTransportError {
            await handleTransportFailure(error, message: message, body: body, generation: generation)
        } catch {
            await handleSendError(error: error, requestId: Self.requestId(of: message))
        }
    }

    private func performRequest(message: JsonRpcMessage, body: Data, allowRecovery: Bool) async throws {
        let requestId = Self.requestId(of: message)
        let isInitialize = Self.method(of: message) == Self.initializeMethod
        let credentials = await credentialsProvider.currentCredentials()
        let request = makePostRequest(credentials: credentials, body: body, isInitialize: isInitialize)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await urlSession.bytes(for: request)
        } catch {
            throw Self.mapRequestFailure(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPTransportError.readFailed(detail: "non-HTTP response")
        }

        let status = httpResponse.statusCode
        if allowRecovery, let recovery = recoveryError(forStatus: status, isInitialize: isInitialize) {
            throw recovery
        }

        captureSessionIdIfPresent(from: httpResponse)

        let contentType = headerValue(httpResponse, name: "Content-Type")?.lowercased() ?? ""

        if (200..<300).contains(status) {
            if contentType.contains("text/event-stream") {
                try await consumeSseBytes(bytes)
                return
            }
            let data = try await collectBytes(bytes)
            if data.isEmpty {
                return
            }
            captureNegotiatedProtocolVersion(from: data, isInitialize: isInitialize)
            pushJsonBody(data, fallbackId: requestId)
            return
        }

        let data = try await collectBytes(bytes)
        handleNonSuccessResponse(
            status: status,
            headers: httpResponse,
            body: data,
            requestId: requestId
        )
    }

    private func makePostRequest(
        credentials: MCPUpstreamCredentials,
        body: Data,
        isInitialize: Bool
    ) -> URLRequest {
        var request = URLRequest(url: credentials.endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(credentials.bearerToken)", forHTTPHeaderField: "Authorization")
        guard !isInitialize else {
            return request
        }
        if let sessionId {
            request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
        }
        if let negotiatedProtocolVersion {
            request.setValue(negotiatedProtocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        return request
    }

    private func recoveryError(forStatus status: Int, isInitialize: Bool) -> MCPTransportError? {
        guard cachedInitializeRequest != nil else {
            return nil
        }
        if status == 401 {
            return .authentication(httpStatus: status, message: "Upstream rejected the bridge token")
        }
        if status == 404, !isInitialize, sessionId != nil {
            return .sessionExpired
        }
        return nil
    }

    private func handleTransportFailure(
        _ error: MCPTransportError,
        message: JsonRpcMessage,
        body: Data,
        generation: Int
    ) async {
        if Task.isCancelled || isClosed {
            return
        }

        guard cachedInitializeRequest != nil, let reason = Self.recoveryReason(for: error) else {
            await handleSendError(error: error, requestId: Self.requestId(of: message))
            return
        }

        await recoverAndReplay(reason: reason, message: message, body: body, generation: generation)
    }

    private func recoverAndReplay(
        reason: MCPUpstreamRecoveryReason,
        message: JsonRpcMessage,
        body: Data,
        generation: Int
    ) async {
        do {
            try await runRecovery(
                reason: reason,
                originatingMethod: Self.method(of: message),
                generation: generation
            )
        } catch {
            errorLogger?.log(.error, "Upstream session recovery failed: \(error)")
            yieldUpstreamUnavailable(requestId: Self.requestId(of: message))
            return
        }

        guard !isClosed, !Task.isCancelled else {
            return
        }

        do {
            try await performRequest(message: message, body: body, allowRecovery: false)
        } catch {
            await handleSendError(error: error, requestId: Self.requestId(of: message))
        }
    }

    private func runRecovery(
        reason: MCPUpstreamRecoveryReason,
        originatingMethod: String?,
        generation: Int
    ) async throws {
        try await recoveryCoordinator.execute(key: Self.recoveryKey) { [weak self] in
            guard let self else { return }
            try await self.performRecovery(
                reason: reason,
                originatingMethod: originatingMethod,
                generation: generation
            )
        }
    }

    private func performRecovery(
        reason: MCPUpstreamRecoveryReason,
        originatingMethod: String?,
        generation: Int
    ) async throws {
        guard sessionGeneration == generation else {
            return
        }

        if reason == .credentialsRejected {
            _ = try await credentialsProvider.refreshCredentials()
        }

        if originatingMethod != Self.initializeMethod {
            try await reinitializeSession()
        }

        sessionGeneration += 1
    }

    private func reinitializeSession() async throws {
        guard let cached = cachedInitializeRequest else {
            throw MCPUpstreamRecoveryError.noCachedInitialize
        }

        let internalId = Self.internalRequestId(purpose: "reinit")
        let outcome = try await executeInternalExchange(
            message: .request(
                JsonRpcRequest(id: internalId, method: Self.initializeMethod, params: cached.params)
            )
        )

        guard (200..<300).contains(outcome.status),
              case .successResponse(let success)? = outcome.message,
              success.id == internalId,
              let refreshedSessionId = outcome.sessionId else {
            throw MCPUpstreamRecoveryError.reinitializeFailed(status: outcome.status)
        }

        sessionId = refreshedSessionId
        negotiatedProtocolVersion = success.result["protocolVersion"]?.stringValue

        if let notification = cachedInitializedNotification {
            let acknowledgement = try await executeInternalExchange(message: .notification(notification))
            guard (200..<300).contains(acknowledgement.status) else {
                throw MCPUpstreamRecoveryError.initializedNotificationFailed(status: acknowledgement.status)
            }
        }

        errorLogger?.log(.info, "Re-established upstream MCP session after \(refreshedSessionId.prefix(8))")
    }

    private func executeInternalExchange(message: JsonRpcMessage) async throws -> InternalExchangeOutcome {
        let body: Data
        do {
            body = try JsonRpcCodec.encode(message)
        } catch {
            throw MCPTransportError.writeFailed(detail: String(describing: error))
        }

        let isInitialize = Self.method(of: message) == Self.initializeMethod
        let credentials = await credentialsProvider.currentCredentials()
        let request = makePostRequest(credentials: credentials, body: body, isInitialize: isInitialize)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await urlSession.bytes(for: request)
        } catch {
            throw Self.mapRequestFailure(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPTransportError.readFailed(detail: "non-HTTP response")
        }

        let data = try await collectBytes(bytes)
        let contentType = headerValue(httpResponse, name: "Content-Type")?.lowercased() ?? ""

        return InternalExchangeOutcome(
            status: httpResponse.statusCode,
            sessionId: headerValue(httpResponse, name: "Mcp-Session-Id"),
            message: await Self.decodeInternalBody(data, contentType: contentType)
        )
    }

    private func startKeepaliveIfNeeded() {
        guard !keepaliveStarted, configuration.keepaliveInterval != nil else {
            return
        }
        keepaliveStarted = true

        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.runKeepaliveLoop()
        }
        trackTask(task)
    }

    private func runKeepaliveLoop() async {
        guard let interval = configuration.keepaliveInterval else {
            return
        }
        while !Task.isCancelled, !isClosed {
            do {
                try await clock.sleep(for: interval)
            } catch {
                return
            }
            guard !Task.isCancelled, !isClosed else {
                return
            }
            await sendKeepalivePing()
        }
    }

    private func sendKeepalivePing() async {
        guard sessionId != nil else {
            return
        }

        let generation = sessionGeneration
        let ping = JsonRpcMessage.request(
            JsonRpcRequest(id: Self.internalRequestId(purpose: "ping"), method: Self.pingMethod, params: nil)
        )

        let outcome: InternalExchangeOutcome
        do {
            outcome = try await executeInternalExchange(message: ping)
        } catch {
            errorLogger?.log(.warning, "Keepalive ping failed: \(error)")
            return
        }

        guard let failure = recoveryError(forStatus: outcome.status, isInitialize: false),
              let reason = Self.recoveryReason(for: failure) else {
            return
        }

        do {
            try await runRecovery(
                reason: reason,
                originatingMethod: Self.pingMethod,
                generation: generation
            )
        } catch {
            errorLogger?.log(.warning, "Keepalive recovery failed: \(error)")
        }
    }

    private func terminateUpstreamSession() async {
        guard let sessionId else {
            return
        }

        let credentials = await credentialsProvider.currentCredentials()
        var request = URLRequest(url: credentials.endpoint)
        request.httpMethod = "DELETE"
        request.timeoutInterval = Self.sessionTerminationTimeout
        request.setValue("Bearer \(credentials.bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")

        _ = try? await urlSession.bytes(for: request)
        self.sessionId = nil
    }

    private func runServerInitiatedStream() async {
        do {
            let credentials = await credentialsProvider.currentCredentials()
            var request = URLRequest(url: credentials.endpoint)
            request.httpMethod = "GET"
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(credentials.bearerToken)", forHTTPHeaderField: "Authorization")
            if let sessionId {
                request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
            }

            let (bytes, response) = try await urlSession.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                errorLogger?.log(.warning, "server-initiated stream: non-HTTP response")
                return
            }
            captureSessionIdIfPresent(from: httpResponse)
            let status = httpResponse.statusCode
            guard (200..<300).contains(status) else {
                let body = try await collectBytes(bytes)
                handleNonSuccessResponse(
                    status: status,
                    headers: httpResponse,
                    body: body,
                    requestId: nil
                )
                return
            }
            try await consumeSseBytes(bytes)
        } catch {
            if Task.isCancelled {
                return
            }
            errorLogger?.log(.warning, "server-initiated stream ended: \(error)")
        }
    }

    private func consumeSseBytes(_ bytes: URLSession.AsyncBytes) async throws {
        let decoder = SseDecoder()
        var chunk = Data()
        for try await byte in bytes {
            if Task.isCancelled {
                return
            }
            chunk.append(byte)
            if byte == 0x0A {
                let frames = await decoder.feed(chunk)
                chunk.removeAll(keepingCapacity: true)
                for frame in frames {
                    pushSseFrame(frame)
                }
            }
        }
        if !chunk.isEmpty {
            let frames = await decoder.feed(chunk)
            for frame in frames {
                pushSseFrame(frame)
            }
        }
    }

    private func collectBytes(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            if Task.isCancelled {
                return data
            }
            data.append(byte)
        }
        return data
    }

    private func pushSseFrame(_ frame: SseFrame) {
        guard let payload = frame.data.data(using: .utf8) else { return }
        if payload.isEmpty {
            return
        }
        do {
            let message = try JsonRpcCodec.decode(payload)
            continuation.yield(message)
        } catch {
            errorLogger?.log(.warning, "SSE: skipping malformed JSON-RPC frame: \(error)")
        }
    }

    private func pushJsonBody(_ data: Data, fallbackId: JsonRpcId?) {
        do {
            let message = try JsonRpcCodec.decode(data)
            continuation.yield(message)
        } catch {
            errorLogger?.log(.warning, "HTTP: malformed JSON-RPC body: \(error)")
            let synthetic = MCPProtocolError.parseError(detail: String(describing: error))
                .toJsonRpcErrorResponse(id: fallbackId)
            continuation.yield(.errorResponse(synthetic))
        }
    }

    private func handleNonSuccessResponse(
        status: Int,
        headers: HTTPURLResponse,
        body: Data,
        requestId: JsonRpcId?
    ) {
        if requestId == nil {
            errorLogger?.log(.warning, "HTTP \(status) for notification (no response will be emitted)")
            return
        }

        if !body.isEmpty, let parsed = try? JsonRpcCodec.decode(body) {
            if case .errorResponse = parsed {
                continuation.yield(parsed)
                return
            }
            if case .successResponse = parsed {
                continuation.yield(parsed)
                return
            }
        }

        let challenge = headerValue(headers, name: "WWW-Authenticate") ?? "Bearer realm=\"TablePro\""
        let protocolError = Self.protocolError(forStatus: status, body: body, challenge: challenge)
        let response = protocolError.toJsonRpcErrorResponse(id: requestId)
        continuation.yield(.errorResponse(response))
    }

    private func handleSendError(error: Error, requestId: JsonRpcId?) async {
        if Task.isCancelled {
            return
        }
        errorLogger?.log(.error, "HTTP send failed: \(error)")
        guard let requestId else {
            return
        }
        if case MCPTransportError.unreachable = error {
            yieldUpstreamUnavailable(requestId: requestId)
            return
        }
        let protocolError = MCPProtocolError.internalError(detail: String(describing: error))
        let response = protocolError.toJsonRpcErrorResponse(id: requestId)
        continuation.yield(.errorResponse(response))
    }

    private func yieldUpstreamUnavailable(requestId: JsonRpcId?) {
        guard let requestId else {
            return
        }
        let response = JsonRpcErrorResponse(
            id: requestId,
            error: JsonRpcError(code: JsonRpcErrorCode.serverError, message: Self.unavailableMessage)
        )
        continuation.yield(.errorResponse(response))
    }

    private func captureSessionIdIfPresent(from response: HTTPURLResponse) {
        guard let value = headerValue(response, name: "Mcp-Session-Id") else { return }
        sessionId = value
    }

    private func captureNegotiatedProtocolVersion(from data: Data, isInitialize: Bool) {
        guard isInitialize,
              let message = try? JsonRpcCodec.decode(data),
              case .successResponse(let success) = message,
              let version = success.result["protocolVersion"]?.stringValue else { return }
        negotiatedProtocolVersion = version
    }

    private func headerValue(_ response: HTTPURLResponse, name: String) -> String? {
        let target = name.lowercased()
        for (rawKey, rawValue) in response.allHeaderFields {
            guard let key = rawKey as? String,
                  key.lowercased() == target,
                  let value = rawValue as? String else { continue }
            return value
        }
        return nil
    }

    private static func decodeInternalBody(_ data: Data, contentType: String) async -> JsonRpcMessage? {
        guard !data.isEmpty else { return nil }

        guard contentType.contains("text/event-stream") else {
            return try? JsonRpcCodec.decode(data)
        }

        let decoder = SseDecoder()
        let frames = await decoder.feed(data)
        for frame in frames {
            guard let payload = frame.data.data(using: .utf8),
                  let message = try? JsonRpcCodec.decode(payload) else { continue }
            return message
        }
        return nil
    }

    private static func internalRequestId(purpose: String) -> JsonRpcId {
        .string("__tablepro_bridge_\(purpose)_\(UUID().uuidString)")
    }

    private static func recoveryReason(for error: MCPTransportError) -> MCPUpstreamRecoveryReason? {
        switch error {
        case .sessionExpired:
            return .sessionExpired
        case .authentication, .unreachable:
            return .credentialsRejected
        default:
            return nil
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

    private static func requestId(of message: JsonRpcMessage) -> JsonRpcId? {
        switch message {
        case .request(let request):
            return request.id
        case .notification:
            return nil
        case .successResponse(let response):
            return response.id
        case .errorResponse(let response):
            return response.id
        }
    }

    private static func method(of message: JsonRpcMessage) -> String? {
        switch message {
        case .request(let request):
            return request.method
        case .notification(let notification):
            return notification.method
        case .successResponse, .errorResponse:
            return nil
        }
    }

    private static func protocolError(forStatus status: Int, body: Data, challenge: String) -> MCPProtocolError {
        let detail = String(data: body, encoding: .utf8) ?? "HTTP \(status)"
        switch status {
        case 400:
            return .invalidRequest(detail: detail)
        case 401:
            return .unauthenticated(challenge: challenge)
        case 403:
            return .forbidden(reason: detail)
        case 404:
            return .sessionNotFound(message: detail.isEmpty ? "Session not found" : detail)
        case 406:
            return .notAcceptable()
        case 413:
            return .payloadTooLarge()
        case 415:
            return .unsupportedMediaType()
        case 429:
            return .rateLimited()
        case 503:
            return .serviceUnavailable()
        default:
            return .internalError(detail: detail)
        }
    }

    private struct InternalExchangeOutcome: Sendable {
        let status: Int
        let sessionId: String?
        let message: JsonRpcMessage?
    }
}

private final class CertificatePinningDelegate: NSObject, URLSessionDelegate {
    private let expectedFingerprint: @Sendable () async -> String?
    private let errorLogger: (any MCPBridgeLogger)?

    init(
        expectedFingerprint: @escaping @Sendable () async -> String?,
        errorLogger: (any MCPBridgeLogger)?
    ) {
        self.expectedFingerprint = expectedFingerprint
        self.errorLogger = errorLogger
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }

        guard let expected = await expectedFingerprint() else {
            return (.performDefaultHandling, nil)
        }

        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            errorLogger?.log(.error, "TLS pinning: empty cert chain")
            return (.cancelAuthenticationChallenge, nil)
        }

        let fingerprint = Self.sha256Fingerprint(of: leaf)
        if fingerprint.caseInsensitiveCompare(expected) != .orderedSame {
            let prefix = String(fingerprint.prefix(8))
            errorLogger?.log(.error, "TLS pinning: cert mismatch (got \(prefix)...)")
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }

    private static func sha256Fingerprint(of certificate: SecCertificate) -> String {
        let data = SecCertificateCopyData(certificate) as Data
        return SHA256.hash(data: data)
            .map { String(format: "%02X", $0) }
            .joined(separator: ":")
    }
}
