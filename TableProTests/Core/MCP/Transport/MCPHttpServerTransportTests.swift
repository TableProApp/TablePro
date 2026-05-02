import Foundation
@testable import TablePro
import Testing

@Suite("MCP HTTP Server Transport")
struct MCPHttpServerTransportTests {
    private static let mcpVersion = "2024-11-05"

    private func makeTransport(
        authenticator: any MCPAuthenticator,
        clock: any MCPClock = MCPSystemClock(),
        sessionPolicy: MCPSessionPolicy = MCPSessionPolicy(
            idleTimeout: .seconds(900),
            maxSessions: 16,
            cleanupInterval: .seconds(60)
        )
    ) -> (MCPHttpServerTransport, MCPSessionStore) {
        let store = MCPSessionStore(policy: sessionPolicy, clock: clock)
        let config = MCPHttpServerConfiguration.loopback(port: 0)
        let transport = MCPHttpServerTransport(
            configuration: config,
            sessionStore: store,
            authenticator: authenticator,
            clock: clock
        )
        return (transport, store)
    }

    private func startedTransport(
        authenticator: any MCPAuthenticator,
        clock: any MCPClock = MCPSystemClock(),
        sessionPolicy: MCPSessionPolicy = MCPSessionPolicy(
            idleTimeout: .seconds(900),
            maxSessions: 16,
            cleanupInterval: .seconds(60)
        )
    ) async throws -> (MCPHttpServerTransport, MCPSessionStore, UInt16) {
        let (transport, store) = makeTransport(
            authenticator: authenticator,
            clock: clock,
            sessionPolicy: sessionPolicy
        )

        let stateStream = transport.listenerState
        let stateTask = Task<UInt16?, Never> {
            for await state in stateStream {
                if case .running(let port) = state {
                    return port
                }
                if case .failed = state {
                    return nil
                }
            }
            return nil
        }

        try await transport.start()
        guard let port = await stateTask.value, port != 0 else {
            await transport.stop()
            throw TestError.serverDidNotStart
        }
        return (transport, store, port)
    }

    private func makePost(
        port: UInt16,
        body: Data,
        sessionId: String? = nil,
        authorization: String? = "Bearer test-token",
        contentType: String = "application/json"
    ) -> URLRequest {
        guard let url = URL(string: "http://127.0.0.1:\(port)/mcp") else {
            fatalError("Failed to construct test URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(Self.mcpVersion, forHTTPHeaderField: "mcp-protocol-version")
        if let sessionId {
            request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
        }
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func makeOptions(port: UInt16, origin: String? = "http://localhost") -> URLRequest {
        guard let url = URL(string: "http://127.0.0.1:\(port)/mcp") else {
            fatalError("Failed to construct test URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "OPTIONS"
        request.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")
        if let origin {
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }
        return request
    }

    private func makeRequestBody(method: String, id: Int = 1) throws -> Data {
        let request = JsonRpcRequest(id: .number(Int64(id)), method: method, params: nil)
        return try JsonRpcCodec.encode(.request(request))
    }

    private func parseJsonRpcError(_ data: Data) throws -> (id: JsonRpcId?, code: Int, message: String) {
        let decoded = try JsonRpcCodec.decode(data)
        guard case .errorResponse(let envelope) = decoded else {
            throw TestError.expectedErrorEnvelope
        }
        return (envelope.id, envelope.error.code, envelope.error.message)
    }

    private func runEchoLoop(
        transport: MCPHttpServerTransport,
        consumer: StubExchangeConsumer,
        successResult: JsonValue = .object(["ok": .bool(true)])
    ) async {
        await consumer.start(transport: transport) { exchange in
            switch exchange.message {
            case .request(let request):
                let response = JsonRpcMessage.successResponse(
                    JsonRpcSuccessResponse(id: request.id, result: successResult)
                )
                await exchange.responder.respond(response, sessionId: exchange.context.sessionId)
            case .notification:
                await exchange.responder.acknowledgeAccepted()
            default:
                await exchange.responder.respondError(.invalidRequest(detail: "unsupported"), requestId: nil)
            }
        }
    }

    @Test("Initialize creates session and returns Mcp-Session-Id header")
    func initializeCreatesSession() async throws {
        let auth = StubAlwaysAllowAuthenticator()
        let (transport, _, port) = try await startedTransport(authenticator: auth)
        defer { Task { await transport.stop() } }

        let consumer = StubExchangeConsumer()
        await runEchoLoop(transport: transport, consumer: consumer)
        defer { Task { await consumer.stop() } }

        let body = try makeRequestBody(method: "initialize")
        let request = makePost(port: port, body: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try #require(response as? HTTPURLResponse)

        #expect(httpResponse.statusCode == 200)
        #expect(httpResponse.value(forHTTPHeaderField: "Mcp-Session-Id") != nil)

        let decoded = try JsonRpcCodec.decode(data)
        guard case .successResponse = decoded else {
            Issue.record("Expected success response, got \(decoded)")
            return
        }
    }

    @Test("Tool call with valid session returns 200 and session header")
    func toolCallWithValidSession() async throws {
        let auth = StubAlwaysAllowAuthenticator()
        let (transport, _, port) = try await startedTransport(authenticator: auth)
        defer { Task { await transport.stop() } }

        let consumer = StubExchangeConsumer()
        await runEchoLoop(transport: transport, consumer: consumer)
        defer { Task { await consumer.stop() } }

        let initBody = try makeRequestBody(method: "initialize", id: 1)
        let (_, initResponse) = try await URLSession.shared.data(for: makePost(port: port, body: initBody))
        let initHttp = try #require(initResponse as? HTTPURLResponse)
        let sessionId = try #require(initHttp.value(forHTTPHeaderField: "Mcp-Session-Id"))

        let toolBody = try makeRequestBody(method: "tools/call", id: 2)
        let (toolData, toolResponse) = try await URLSession.shared.data(
            for: makePost(port: port, body: toolBody, sessionId: sessionId)
        )
        let toolHttp = try #require(toolResponse as? HTTPURLResponse)

        #expect(toolHttp.statusCode == 200)
        let decoded = try JsonRpcCodec.decode(toolData)
        guard case .successResponse = decoded else {
            Issue.record("Expected success response, got \(decoded)")
            return
        }
    }

    @Test("Tool call without session id returns 400 with JSON-RPC error envelope")
    func toolCallMissingSessionId() async throws {
        let auth = StubAlwaysAllowAuthenticator()
        let (transport, _, port) = try await startedTransport(authenticator: auth)
        defer { Task { await transport.stop() } }

        let consumer = StubExchangeConsumer()
        await runEchoLoop(transport: transport, consumer: consumer)
        defer { Task { await consumer.stop() } }

        let body = try makeRequestBody(method: "tools/call", id: 7)
        let (data, response) = try await URLSession.shared.data(for: makePost(port: port, body: body))
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 400)
        let parsed = try parseJsonRpcError(data)
        #expect(parsed.code == JsonRpcErrorCode.invalidRequest)
    }

    @Test("Tool call with stale session id returns 404 with JSON-RPC error envelope")
    func toolCallStaleSession() async throws {
        let auth = StubAlwaysAllowAuthenticator()
        let (transport, _, port) = try await startedTransport(authenticator: auth)
        defer { Task { await transport.stop() } }

        let consumer = StubExchangeConsumer()
        await runEchoLoop(transport: transport, consumer: consumer)
        defer { Task { await consumer.stop() } }

        let body = try makeRequestBody(method: "tools/call", id: 8)
        let (data, response) = try await URLSession.shared.data(
            for: makePost(port: port, body: body, sessionId: "nonexistent-session-id")
        )
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 404)
        let parsed = try parseJsonRpcError(data)
        #expect(parsed.code == JsonRpcErrorCode.sessionNotFound)
    }

    @Test("Missing Authorization returns 401 with WWW-Authenticate")
    func missingAuthorization() async throws {
        let auth = StubBearerAuthenticator(validToken: "valid")
        let (transport, _, port) = try await startedTransport(authenticator: auth)
        defer { Task { await transport.stop() } }

        let consumer = StubExchangeConsumer()
        await runEchoLoop(transport: transport, consumer: consumer)
        defer { Task { await consumer.stop() } }

        let body = try makeRequestBody(method: "initialize", id: 1)
        let request = makePost(port: port, body: body, authorization: nil)
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 401)
        let challenge = http.value(forHTTPHeaderField: "Www-Authenticate") ?? http.value(forHTTPHeaderField: "WWW-Authenticate")
        #expect(challenge?.contains("Bearer") == true)
        let parsed = try parseJsonRpcError(data)
        #expect(parsed.code != 0)
    }

    @Test("Bad bearer token returns 401 with JSON-RPC error envelope")
    func badBearerToken() async throws {
        let auth = StubBearerAuthenticator(validToken: "valid")
        let (transport, _, port) = try await startedTransport(authenticator: auth)
        defer { Task { await transport.stop() } }

        let consumer = StubExchangeConsumer()
        await runEchoLoop(transport: transport, consumer: consumer)
        defer { Task { await consumer.stop() } }

        let body = try makeRequestBody(method: "initialize", id: 1)
        let request = makePost(port: port, body: body, authorization: "Bearer wrong-token")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 401)
        let parsed = try parseJsonRpcError(data)
        #expect(parsed.code != 0)
    }

    @Test("Rate limit kicks in after repeated bad attempts and includes Retry-After")
    func rateLimitAfterBadAttempts() async throws {
        let auth = StubBearerAuthenticator(validToken: "valid", maxAttempts: 3)
        let (transport, _, port) = try await startedTransport(authenticator: auth)
        defer { Task { await transport.stop() } }

        let consumer = StubExchangeConsumer()
        await runEchoLoop(transport: transport, consumer: consumer)
        defer { Task { await consumer.stop() } }

        let body = try makeRequestBody(method: "initialize", id: 1)

        for _ in 0..<3 {
            let request = makePost(port: port, body: body, authorization: "Bearer wrong-token")
            _ = try await URLSession.shared.data(for: request)
        }

        let request = makePost(port: port, body: body, authorization: "Bearer wrong-token")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 429)
        let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
        #expect(retryAfter == "30")
        let parsed = try parseJsonRpcError(data)
        #expect(parsed.code != 0)
    }

    @Test("Payload too large returns 413 with JSON-RPC error envelope")
    func payloadTooLarge() async throws {
        let auth = StubAlwaysAllowAuthenticator()
        let limits = MCPHttpServerLimits(
            maxRequestBodyBytes: 1_024,
            maxHeaderBytes: 16 * 1_024,
            connectionTimeout: .seconds(30)
        )
        let store = MCPSessionStore()
        let config = MCPHttpServerConfiguration.loopback(port: 0, limits: limits)
        let transport = MCPHttpServerTransport(
            configuration: config,
            sessionStore: store,
            authenticator: auth
        )

        let stateStream = transport.listenerState
        let stateTask = Task<UInt16?, Never> {
            for await state in stateStream {
                if case .running(let port) = state { return port }
                if case .failed = state { return nil }
            }
            return nil
        }
        try await transport.start()
        let port = try #require(await stateTask.value)
        defer { Task { await transport.stop() } }

        let consumer = StubExchangeConsumer()
        await runEchoLoop(transport: transport, consumer: consumer)
        defer { Task { await consumer.stop() } }

        let bigBody = Data(repeating: 0x41, count: 2_048)
        let request = makePost(port: port, body: bigBody)
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 413)
    }

    @Test("Method not found at unknown path returns 404 with JSON-RPC error envelope")
    func unknownPathReturns404() async throws {
        let auth = StubAlwaysAllowAuthenticator()
        let (transport, _, port) = try await startedTransport(authenticator: auth)
        defer { Task { await transport.stop() } }

        let consumer = StubExchangeConsumer()
        await runEchoLoop(transport: transport, consumer: consumer)
        defer { Task { await consumer.stop() } }

        guard let url = URL(string: "http://127.0.0.1:\(port)/foo") else {
            Issue.record("Failed to construct URL")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer test", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 404)
        let parsed = try parseJsonRpcError(data)
        #expect(parsed.code == JsonRpcErrorCode.methodNotFound)
    }

    @Test("OPTIONS request returns 204 with CORS headers reflecting allowed origin")
    func optionsReturnsNoContent() async throws {
        let auth = StubAlwaysAllowAuthenticator()
        let (transport, _, port) = try await startedTransport(authenticator: auth)
        defer { Task { await transport.stop() } }

        let request = makeOptions(port: port, origin: "http://localhost")
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 204)
        let allowOrigin = http.value(forHTTPHeaderField: "Access-Control-Allow-Origin")
        #expect(allowOrigin == "http://localhost")
        let allowHeaders = http.value(forHTTPHeaderField: "Access-Control-Allow-Headers")
        #expect(allowHeaders?.contains("Last-Event-ID") == true)
    }

    @Test("OPTIONS request from disallowed origin omits CORS headers")
    func optionsDisallowedOriginOmitsCors() async throws {
        let auth = StubAlwaysAllowAuthenticator()
        let (transport, _, port) = try await startedTransport(authenticator: auth)
        defer { Task { await transport.stop() } }

        let request = makeOptions(port: port, origin: "https://evil.example.com")
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 204)
        #expect(http.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == nil)
    }

    @Test("OPTIONS request without Origin header omits CORS headers")
    func optionsWithoutOriginOmitsCors() async throws {
        let auth = StubAlwaysAllowAuthenticator()
        let (transport, _, port) = try await startedTransport(authenticator: auth)
        defer { Task { await transport.stop() } }

        let request = makeOptions(port: port, origin: nil)
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 204)
        #expect(http.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == nil)
    }

    @Test("Initialize with unsupported protocolVersion returns invalid_request error")
    func initializeRejectsUnsupportedProtocolVersion() async throws {
        let auth = StubAlwaysAllowAuthenticator()
        let (transport, _, port) = try await startedTransport(authenticator: auth)
        defer { Task { await transport.stop() } }

        let consumer = StubExchangeConsumer()
        let store = MCPSessionStore()
        let progressSink = NullProgressSink()
        let dispatcher = MCPProtocolDispatcher(
            handlers: [InitializeHandler()],
            sessionStore: store,
            progressSink: progressSink
        )
        await consumer.start(transport: transport) { exchange in
            await dispatcher.dispatch(exchange)
        }
        defer { Task { await consumer.stop() } }

        let request = JsonRpcRequest(
            id: .number(1),
            method: "initialize",
            params: .object(["protocolVersion": .string("1999-01-01")])
        )
        let body = try JsonRpcCodec.encode(.request(request))
        let httpRequest = makePost(port: port, body: body)
        let (data, response) = try await URLSession.shared.data(for: httpRequest)
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 400)
        let parsed = try parseJsonRpcError(data)
        #expect(parsed.code == JsonRpcErrorCode.invalidRequest)
    }

    @Test("Subsequent request with mismatched MCP-Protocol-Version is rejected")
    func mismatchedProtocolVersionHeaderRejected() async throws {
        let auth = StubAlwaysAllowAuthenticator()
        let (transport, _, port) = try await startedTransport(authenticator: auth)
        defer { Task { await transport.stop() } }

        let consumer = StubExchangeConsumer()
        let store = MCPSessionStore()
        let progressSink = NullProgressSink()
        let dispatcher = MCPProtocolDispatcher(
            handlers: [InitializeHandler(), PingHandler()],
            sessionStore: store,
            progressSink: progressSink
        )
        await consumer.start(transport: transport) { exchange in
            await dispatcher.dispatch(exchange)
        }
        defer { Task { await consumer.stop() } }

        let initializeRequest = JsonRpcRequest(
            id: .number(1),
            method: "initialize",
            params: .object(["protocolVersion": .string(InitializeHandler.supportedProtocolVersion)])
        )
        let initBody = try JsonRpcCodec.encode(.request(initializeRequest))
        let (_, initResponse) = try await URLSession.shared.data(for: makePost(port: port, body: initBody))
        let initHttp = try #require(initResponse as? HTTPURLResponse)
        let sessionId = try #require(initHttp.value(forHTTPHeaderField: "Mcp-Session-Id"))

        let initialized = JsonRpcNotification(method: "notifications/initialized", params: nil)
        let initializedBody = try JsonRpcCodec.encode(.notification(initialized))
        var initializedRequest = makePost(port: port, body: initializedBody, sessionId: sessionId)
        _ = try await URLSession.shared.data(for: initializedRequest)
        _ = initializedRequest

        let pingRequest = JsonRpcRequest(id: .number(2), method: "ping", params: nil)
        let pingBody = try JsonRpcCodec.encode(.request(pingRequest))
        guard let url = URL(string: "http://127.0.0.1:\(port)/mcp") else {
            Issue.record("Failed to construct URL")
            return
        }
        var mismatched = URLRequest(url: url)
        mismatched.httpMethod = "POST"
        mismatched.httpBody = pingBody
        mismatched.setValue("application/json", forHTTPHeaderField: "Content-Type")
        mismatched.setValue("1999-01-01", forHTTPHeaderField: "mcp-protocol-version")
        mismatched.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
        mismatched.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: mismatched)
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 400)
        let parsed = try parseJsonRpcError(data)
        #expect(parsed.code == JsonRpcErrorCode.invalidRequest)
    }

    @Test("GET /mcp opens an SSE stream that delivers server-sent notifications")
    func getMcpStreamsServerNotifications() async throws {
        let auth = StubAlwaysAllowAuthenticator()
        let (transport, _, port) = try await startedTransport(authenticator: auth)
        defer { Task { await transport.stop() } }

        let consumer = StubExchangeConsumer()
        await runEchoLoop(transport: transport, consumer: consumer)
        defer { Task { await consumer.stop() } }

        let initBody = try makeRequestBody(method: "initialize")
        let (_, initResponse) = try await URLSession.shared.data(for: makePost(port: port, body: initBody))
        let initHttp = try #require(initResponse as? HTTPURLResponse)
        let sessionId = try #require(initHttp.value(forHTTPHeaderField: "Mcp-Session-Id"))

        guard let url = URL(string: "http://127.0.0.1:\(port)/mcp") else {
            Issue.record("Failed to construct URL")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
        request.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 5

        let session = URLSession(configuration: .ephemeral)
        let streamTask = Task<(Int, String), Error> {
            let (bytes, response) = try await session.bytes(for: request)
            let httpResponse = response as? HTTPURLResponse
            var collected = ""
            for try await line in bytes.lines {
                collected += line + "\n"
                if collected.contains("notifications/test") { break }
            }
            return (httpResponse?.statusCode ?? 0, collected)
        }

        try await Task.sleep(for: .milliseconds(200))

        let notification = JsonRpcNotification(
            method: "notifications/test",
            params: .object(["progress": .double(0.5)])
        )
        await transport.sendNotification(notification, toSession: MCPSessionId(sessionId))

        let (status, body) = try await streamTask.value
        #expect(status == 200)
        #expect(body.contains("notifications/test"))
        session.invalidateAndCancel()
    }

    @Test("Idle session eviction terminates SSE-tracked sessions")
    func idleSessionEviction() async throws {
        let clock = MCPTestClock(start: Date(timeIntervalSince1970: 1_000_000))
        let auth = StubAlwaysAllowAuthenticator()
        let policy = MCPSessionPolicy(
            idleTimeout: .seconds(60),
            maxSessions: 16,
            cleanupInterval: .seconds(60)
        )
        let (transport, store, port) = try await startedTransport(
            authenticator: auth,
            clock: clock,
            sessionPolicy: policy
        )
        defer { Task { await transport.stop() } }

        let consumer = StubExchangeConsumer()
        await runEchoLoop(transport: transport, consumer: consumer)
        defer { Task { await consumer.stop() } }

        let initBody = try makeRequestBody(method: "initialize")
        let (_, initResponse) = try await URLSession.shared.data(for: makePost(port: port, body: initBody))
        let initHttp = try #require(initResponse as? HTTPURLResponse)
        let sessionId = try #require(initHttp.value(forHTTPHeaderField: "Mcp-Session-Id"))

        await clock.advance(by: .seconds(120))
        await store.runCleanupPass()

        let body = try makeRequestBody(method: "tools/call", id: 9)
        let request = makePost(port: port, body: body, sessionId: sessionId)
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 404)
        let parsed = try parseJsonRpcError(data)
        #expect(parsed.code == JsonRpcErrorCode.sessionNotFound)
    }
}

private enum TestError: Error {
    case serverDidNotStart
    case expectedErrorEnvelope
}
