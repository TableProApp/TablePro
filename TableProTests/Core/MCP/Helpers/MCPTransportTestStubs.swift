import Foundation
import Network
import TableProPluginKit
@testable import TablePro

actor StubAlwaysAllowAuthenticator: MCPAuthenticator {
    private let principal: MCPPrincipal

    init(scopes: Set<MCPScope> = [.toolsRead, .toolsWrite, .resourcesRead]) {
        principal = MCPPrincipal(
            tokenFingerprint: "stubtoken",
            tokenId: UUID(uuidString: "00000000-0000-0000-0000-0000000057AB"),
            scopes: scopes,
            metadata: MCPPrincipalMetadata(
                label: "stub",
                issuedAt: Date(timeIntervalSince1970: 1_700_000_000),
                expiresAt: nil
            )
        )
    }

    func authenticate(
        authorizationHeader: String?,
        clientAddress: MCPClientAddress
    ) async -> MCPAuthDecision {
        .allow(principal)
    }
}

actor StubBearerAuthenticator: MCPAuthenticator {
    private let validToken: String
    private let principal: MCPPrincipal
    private var attemptsByAddress: [MCPClientAddress: Int] = [:]
    private let maxAttempts: Int

    init(validToken: String, maxAttempts: Int = 5) {
        self.validToken = validToken
        self.maxAttempts = maxAttempts
        principal = MCPPrincipal(
            tokenFingerprint: "fingerprint",
            tokenId: UUID(uuidString: "00000000-0000-0000-0000-0000000057AC"),
            scopes: [.toolsRead, .toolsWrite, .resourcesRead],
            metadata: MCPPrincipalMetadata(
                label: "test",
                issuedAt: Date(timeIntervalSince1970: 1_700_000_000),
                expiresAt: nil
            )
        )
    }

    func authenticate(
        authorizationHeader: String?,
        clientAddress: MCPClientAddress
    ) async -> MCPAuthDecision {
        let attempts = attemptsByAddress[clientAddress] ?? 0
        if attempts >= maxAttempts {
            return .deny(.rateLimited(retryAfterSeconds: 30))
        }

        guard let raw = authorizationHeader, !raw.isEmpty else {
            attemptsByAddress[clientAddress] = attempts + 1
            return .deny(.unauthenticated(reason: "missing"))
        }

        let lowered = raw.lowercased()
        guard lowered.hasPrefix("bearer ") else {
            attemptsByAddress[clientAddress] = attempts + 1
            return .deny(.unauthenticated(reason: "bad scheme"))
        }
        let token = String(raw.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)

        if token == validToken {
            attemptsByAddress[clientAddress] = 0
            return .allow(principal)
        }

        attemptsByAddress[clientAddress] = attempts + 1
        return .deny(.tokenInvalid(reason: "bad token"))
    }
}

actor StubExchangeConsumer {
    private var task: Task<Void, Never>?

    func start(
        transport: MCPHttpServerTransport,
        responder: @escaping @Sendable (MCPInboundExchange) async -> Void
    ) async {
        let stream = transport.exchanges
        task = Task {
            for await exchange in stream {
                await responder(exchange)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

actor TransportTestSignal {
    private var raised: Set<String> = []

    func raise(_ name: String) {
        raised.insert(name)
    }

    func isRaised(_ name: String) -> Bool {
        raised.contains(name)
    }

    func wait(for name: String, timeout: Duration = .seconds(3)) async -> Bool {
        let deadline = TransportTestTime.deadline(timeout)
        while !raised.contains(name) {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
}

actor TransportTestRecorder {
    private var chunks: [Data] = []

    func append(_ data: Data) {
        chunks.append(data)
    }

    func text() -> String {
        var combined = Data()
        for chunk in chunks {
            combined.append(chunk)
        }
        return String(data: combined, encoding: .utf8) ?? ""
    }

    func count() -> Int {
        chunks.count
    }
}

enum TransportTestTime {
    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    static func deadline(_ timeout: Duration) -> Date {
        Date().addingTimeInterval(seconds(timeout))
    }
}

enum RawHttpTestError: Error, Equatable {
    case connectFailed
    case timedOut(String)
    case connectionClosed
    case malformedResponse
}

struct RawHttpTestHeader: Sendable, Equatable {
    let name: String
    let value: String
}

struct RawHttpTestResponse: Sendable, Equatable {
    let statusCode: Int
    let reasonPhrase: String
    let headers: [RawHttpTestHeader]
    let body: Data

    func header(_ name: String) -> String? {
        let lowered = name.lowercased()
        return headers.first { $0.name.lowercased() == lowered }?.value
    }

    func hasHeader(_ name: String) -> Bool {
        header(name) != nil
    }

    var bodyText: String {
        String(data: body, encoding: .utf8) ?? ""
    }

    func jsonRpcError() throws -> JsonRpcError {
        let decoded = try JsonRpcCodec.decode(body)
        guard case .errorResponse(let envelope) = decoded else {
            throw RawHttpTestError.malformedResponse
        }
        return envelope.error
    }

    func jsonRpcResult() throws -> JsonValue {
        let decoded = try JsonRpcCodec.decode(body)
        guard case .successResponse(let envelope) = decoded else {
            throw RawHttpTestError.malformedResponse
        }
        return envelope.result
    }

    func plainJsonField(_ key: String) throws -> String? {
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw RawHttpTestError.malformedResponse
        }
        return object[key] as? String
    }

    func isJsonRpcEnvelope() -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        return object["jsonrpc"] != nil
    }
}

actor RawHttpTestClient {
    private static let receiveChunkSize = 65_536

    private let connection: NWConnection
    private var buffer: [UInt8] = []
    private var everything: [UInt8] = []
    private var ready = false
    private var failed = false
    private var peerClosed = false

    init(port: UInt16) {
        let endpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port) ?? .any
        )
        connection = NWConnection(to: endpoint, using: .tcp)
    }

    func connect(timeout: Duration = .seconds(3)) async throws {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Task { await self.markReady() }
            case .failed:
                Task { await self.markFailed() }
            case .cancelled:
                Task { await self.markPeerClosed() }
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))

        let deadline = TransportTestTime.deadline(timeout)
        while !ready, !failed {
            guard Date() < deadline else { throw RawHttpTestError.timedOut("connect") }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard ready else { throw RawHttpTestError.connectFailed }
        receiveNext()
    }

    func send(_ data: Data) async throws {
        guard !peerClosed else { throw RawHttpTestError.connectionClosed }
        let sendFailed: Bool = await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(returning: error != nil)
            })
        }
        guard !sendFailed else { throw RawHttpTestError.connectionClosed }
    }

    func send(_ text: String) async throws {
        try await send(Data(text.utf8))
    }

    func readResponse(timeout: Duration = .seconds(5)) async throws -> RawHttpTestResponse {
        let deadline = TransportTestTime.deadline(timeout)
        while true {
            if let response = try takeResponse() { return response }
            if peerClosed { throw RawHttpTestError.connectionClosed }
            guard Date() < deadline else { throw RawHttpTestError.timedOut("response") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func readUntil(_ marker: String, timeout: Duration = .seconds(5)) async throws -> String {
        let needle = Array(marker.utf8)
        let deadline = TransportTestTime.deadline(timeout)
        while true {
            if let end = index(of: needle) {
                let slice = Array(buffer[0..<(end + needle.count)])
                buffer.removeFirst(end + needle.count)
                return String(bytes: slice, encoding: .utf8) ?? ""
            }
            if peerClosed { throw RawHttpTestError.connectionClosed }
            guard Date() < deadline else { throw RawHttpTestError.timedOut("marker '\(marker)'") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func waitForClose(timeout: Duration = .seconds(3)) async -> Bool {
        let deadline = TransportTestTime.deadline(timeout)
        while !peerClosed {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    func isPeerClosed() -> Bool {
        peerClosed
    }

    func receivedText() -> String {
        String(bytes: everything, encoding: .utf8) ?? ""
    }

    func pendingText() -> String {
        String(bytes: buffer, encoding: .utf8) ?? ""
    }

    func close() {
        connection.cancel()
    }

    private func markReady() {
        ready = true
    }

    private func markFailed() {
        failed = true
        peerClosed = true
    }

    private func markPeerClosed() {
        peerClosed = true
    }

    private func receiveNext() {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: Self.receiveChunkSize
        ) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            let payload = content
            let ended = isComplete || error != nil
            Task { await self.ingest(payload, ended: ended) }
        }
    }

    private func ingest(_ content: Data?, ended: Bool) {
        if let content, !content.isEmpty {
            buffer.append(contentsOf: content)
            everything.append(contentsOf: content)
        }
        guard !ended else {
            peerClosed = true
            return
        }
        receiveNext()
    }

    private func index(of needle: [UInt8]) -> Int? {
        guard !needle.isEmpty, buffer.count >= needle.count else { return nil }
        for start in 0...(buffer.count - needle.count) where Array(buffer[start..<(start + needle.count)]) == needle {
            return start
        }
        return nil
    }

    private func takeResponse() throws -> RawHttpTestResponse? {
        guard let terminator = index(of: [0x0D, 0x0A, 0x0D, 0x0A]) else { return nil }
        let headText = String(bytes: buffer[0..<terminator], encoding: .utf8) ?? ""
        let lines = headText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw RawHttpTestError.malformedResponse }
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, let code = Int(parts[1]) else { throw RawHttpTestError.malformedResponse }
        let reason = parts.count > 2 ? String(parts[2]) : ""

        var headers: [RawHttpTestHeader] = []
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon])
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers.append(RawHttpTestHeader(name: name, value: value))
        }

        let bodyStart = terminator + 4
        guard let rawLength = headers.first(where: { $0.name.lowercased() == "content-length" })?.value,
              let length = Int(rawLength) else {
            buffer.removeFirst(bodyStart)
            return RawHttpTestResponse(statusCode: code, reasonPhrase: reason, headers: headers, body: Data())
        }
        guard buffer.count >= bodyStart + length else { return nil }
        let body = Data(buffer[bodyStart..<(bodyStart + length)])
        buffer.removeFirst(bodyStart + length)
        return RawHttpTestResponse(statusCode: code, reasonPhrase: reason, headers: headers, body: body)
    }
}

enum MCPTransportTestHarness {
    static func start(
        authenticator: any MCPAuthenticator = StubAlwaysAllowAuthenticator(),
        limits: MCPHttpServerLimits = .standard,
        clock: any MCPClock = MCPSystemClock(),
        timeout: Duration = .seconds(5)
    ) async throws -> (MCPHttpServerTransport, UInt16) {
        let transport = MCPHttpServerTransport(
            configuration: MCPHttpServerConfiguration.loopback(port: 0, limits: limits),
            authenticator: authenticator,
            clock: clock
        )
        try await transport.start()

        let deadline = TransportTestTime.deadline(timeout)
        while true {
            if let port = await transport.listeningPort, port != 0 {
                return (transport, port)
            }
            guard Date() < deadline else {
                await stop(transport)
                throw RawHttpTestError.timedOut("listener")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    static func stop(_ transport: MCPHttpServerTransport, timeout: Duration = .seconds(5)) async {
        let finished = TransportTestSignal()
        let task = Task {
            await transport.stop()
            await finished.raise("stopped")
        }
        guard await finished.wait(for: "stopped", timeout: timeout) else {
            task.cancel()
            return
        }
    }

    static func withServer(
        authenticator: any MCPAuthenticator = StubAlwaysAllowAuthenticator(),
        limits: MCPHttpServerLimits = .standard,
        handler: @escaping @Sendable (MCPInboundExchange) async -> Void = MCPTransportTestHandlers.echo,
        body: (UInt16) async throws -> Void
    ) async throws {
        let (transport, port) = try await start(authenticator: authenticator, limits: limits)
        let consumer = StubExchangeConsumer()
        await consumer.start(transport: transport, responder: handler)
        do {
            try await body(port)
        } catch {
            await consumer.stop()
            await stop(transport)
            throw error
        }
        await consumer.stop()
        await stop(transport)
    }
}

enum MCPTransportTestHandlers {
    static let knownMethods: Set<String> = ["tools/list", "tools/call", "resources/read", "subscriptions/listen"]

    @Sendable
    static func echo(_ exchange: MCPInboundExchange) async {
        switch exchange.message {
        case .request(let request):
            guard knownMethods.contains(request.method) else {
                await exchange.responder.respondError(
                    .methodNotFound(method: request.method),
                    requestId: request.id
                )
                return
            }
            do {
                let meta = try MCPRequestMeta.decodeModern(params: request.params)
                let payload = JsonValue.object([
                    "method": .string(request.method),
                    "protocolVersion": .string(meta.protocolVersion.rawValue)
                ])
                await exchange.responder.respond(
                    .successResponse(JsonRpcSuccessResponse(id: request.id, result: payload))
                )
            } catch let error as MCPProtocolError {
                await exchange.responder.respondError(error, requestId: request.id)
            } catch {
                await exchange.responder.respondError(
                    .internalError(detail: "unexpected"),
                    requestId: request.id
                )
            }
        case .notification:
            await exchange.responder.acknowledgeAccepted()
        case .successResponse, .errorResponse:
            await exchange.responder.respondError(.invalidRequest(detail: "unsupported"), requestId: nil)
        }
    }
}

enum MCPTransportTestRequests {
    static let protocolVersion = MCPProtocolVersion.latest.rawValue
    static let bearerToken = "Bearer test-token"

    static func modernMeta(version: String = protocolVersion) -> JsonValue {
        .object([
            MCPMetaKeys.protocolVersion: .string(version),
            MCPMetaKeys.clientInfo: .object(["name": .string("RawTestClient"), "version": .string("1.0.0")]),
            MCPMetaKeys.clientCapabilities: .object([:])
        ])
    }

    static func params(
        _ fields: [String: JsonValue] = [:],
        version: String = protocolVersion
    ) -> JsonValue {
        var merged = fields
        merged["_meta"] = modernMeta(version: version)
        return .object(merged)
    }

    static func requestBody(
        id: Int,
        method: String,
        params: JsonValue?
    ) throws -> Data {
        try JsonRpcCodec.encode(.request(JsonRpcRequest(id: .number(Int64(id)), method: method, params: params)))
    }

    static func notificationBody(method: String, params: JsonValue?) throws -> Data {
        try JsonRpcCodec.encode(.notification(JsonRpcNotification(method: method, params: params)))
    }

    static func standardHeaders(
        method: String,
        name: String? = nil,
        version: String = protocolVersion
    ) -> [(String, String)] {
        var headers: [(String, String)] = [
            ("Content-Type", "application/json"),
            ("Accept", "application/json, text/event-stream"),
            ("Authorization", bearerToken),
            (MCPHttpHeaderValidator.protocolVersionHeader, version),
            (MCPHttpHeaderValidator.methodHeader, method)
        ]
        if let name {
            headers.append((MCPHttpHeaderValidator.nameHeader, MCPBase64Sentinel.encodeIfNeeded(name)))
        }
        return headers
    }

    static func raw(
        method: String = "POST",
        path: String = "/mcp",
        port: UInt16,
        host: String? = nil,
        headers: [(String, String)] = [],
        body: Data? = nil,
        includeContentLength: Bool = true,
        completeHead: Bool = true
    ) -> Data {
        var text = "\(method) \(path) HTTP/1.1\r\n"
        text += "Host: \(host ?? "127.0.0.1:\(port)")\r\n"
        for (name, value) in headers {
            text += "\(name): \(value)\r\n"
        }
        if includeContentLength {
            text += "Content-Length: \(body?.count ?? 0)\r\n"
        }
        guard completeHead else { return Data(text.utf8) }
        text += "\r\n"
        var data = Data(text.utf8)
        if let body {
            data.append(body)
        }
        return data
    }

    static func modernPost(
        port: UInt16,
        id: Int,
        method: String,
        fields: [String: JsonValue] = [:],
        name: String? = nil,
        version: String = protocolVersion,
        host: String? = nil,
        extraHeaders: [(String, String)] = []
    ) throws -> Data {
        var merged = fields
        if let name {
            let field = method == "resources/read" ? "uri" : "name"
            if merged[field] == nil {
                merged[field] = .string(name)
            }
        }
        let body = try requestBody(id: id, method: method, params: params(merged, version: version))
        var headers = standardHeaders(method: method, name: name, version: version)
        headers.append(contentsOf: extraHeaders)
        return raw(port: port, host: host, headers: headers, body: body)
    }
}
