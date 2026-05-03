import CryptoKit
import Foundation
import Security

public struct MCPStreamableHttpClientConfiguration: Sendable {
    public let endpoint: URL
    public let bearerToken: String
    public let tlsCertFingerprint: String?
    public let requestTimeout: Duration
    public let serverInitiatedStream: Bool

    public init(
        endpoint: URL,
        bearerToken: String,
        tlsCertFingerprint: String? = nil,
        requestTimeout: Duration = .seconds(60),
        serverInitiatedStream: Bool = false
    ) {
        self.endpoint = endpoint
        self.bearerToken = bearerToken
        self.tlsCertFingerprint = tlsCertFingerprint
        self.requestTimeout = requestTimeout
        self.serverInitiatedStream = serverInitiatedStream
    }
}

public actor MCPStreamableHttpClientTransport: MCPMessageTransport {
    nonisolated public let inbound: AsyncThrowingStream<JsonRpcMessage, Error>
    nonisolated private let continuation: AsyncThrowingStream<JsonRpcMessage, Error>.Continuation

    private let configuration: MCPStreamableHttpClientConfiguration
    private let urlSession: URLSession
    private let errorLogger: (any MCPBridgeLogger)?
    private var sessionId: String?
    private var isClosed = false
    private var serverInitiatedStreamOpen = false
    private var tasks: [Task<Void, Never>] = []

    public init(
        configuration: MCPStreamableHttpClientConfiguration,
        urlSession: URLSession? = nil,
        errorLogger: (any MCPBridgeLogger)? = nil
    ) {
        self.configuration = configuration
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
            if let fingerprint = configuration.tlsCertFingerprint {
                let delegate = CertificatePinningDelegate(expectedFingerprint: fingerprint, errorLogger: errorLogger)
                self.urlSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            } else {
                self.urlSession = URLSession(configuration: config)
            }
        }
    }

    public func send(_ message: JsonRpcMessage) async throws {
        if isClosed {
            throw MCPTransportError.closed
        }

        let requestId = Self.requestId(of: message)
        let body: Data
        do {
            body = try JsonRpcCodec.encode(message)
        } catch {
            throw MCPTransportError.writeFailed(detail: String(describing: error))
        }

        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.dispatch(body: body, requestId: requestId)
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

    private func setSessionId(_ value: String) {
        sessionId = value
    }

    private func currentSessionId() -> String? {
        sessionId
    }

    private func dispatch(body: Data, requestId: JsonRpcId?) async {
        do {
            try await performRequest(body: body, requestId: requestId)
        } catch {
            await handleSendError(error: error, requestId: requestId)
        }
    }

    private func performRequest(body: Data, requestId: JsonRpcId?) async throws {
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(configuration.bearerToken)", forHTTPHeaderField: "Authorization")
        if let sessionId = currentSessionId() {
            request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
        }

        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPTransportError.readFailed(detail: "non-HTTP response")
        }

        captureSessionIdIfPresent(from: httpResponse)

        let status = httpResponse.statusCode
        let contentType = headerValue(httpResponse, name: "Content-Type")?.lowercased() ?? ""

        if (200..<300).contains(status) {
            if contentType.contains("text/event-stream") {
                try await consumeSseBytes(bytes)
                return
            }
            if contentType.contains("application/json") {
                let data = try await collectBytes(bytes)
                if data.isEmpty {
                    return
                }
                pushJsonBody(data, fallbackId: requestId)
                return
            }
            let data = try await collectBytes(bytes)
            if data.isEmpty {
                return
            }
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

    private func runServerInitiatedStream() async {
        do {
            var request = URLRequest(url: configuration.endpoint)
            request.httpMethod = "GET"
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(configuration.bearerToken)", forHTTPHeaderField: "Authorization")
            if let sessionId = currentSessionId() {
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
        let protocolError = MCPProtocolError.internalError(detail: String(describing: error))
        let response = protocolError.toJsonRpcErrorResponse(id: requestId)
        continuation.yield(.errorResponse(response))
    }

    private func captureSessionIdIfPresent(from response: HTTPURLResponse) {
        guard let value = headerValue(response, name: "Mcp-Session-Id") else { return }
        setSessionId(value)
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
}

private final class CertificatePinningDelegate: NSObject, URLSessionDelegate {
    private let expectedFingerprint: String
    private let errorLogger: (any MCPBridgeLogger)?

    init(expectedFingerprint: String, errorLogger: (any MCPBridgeLogger)?) {
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

        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            errorLogger?.log(.error, "TLS pinning: empty cert chain")
            return (.cancelAuthenticationChallenge, nil)
        }

        let fingerprint = Self.sha256Fingerprint(of: leaf)
        if fingerprint.caseInsensitiveCompare(expectedFingerprint) != .orderedSame {
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
