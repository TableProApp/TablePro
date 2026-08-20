import Foundation
import Network
import TableProPluginKit
@testable import TablePro
import XCTest

final class MCPStreamableHttpClientTransportTests: XCTestCase {
    private var server: MockHttpServer!

    override func setUp() async throws {
        try await super.setUp()
        server = MockHttpServer()
        try await server.start()
    }

    override func tearDown() async throws {
        await server.stop()
        server = nil
        try await super.tearDown()
    }

    func testJsonResponseArrivesOnInbound() async throws {
        let response = JsonRpcMessage.successResponse(
            JsonRpcSuccessResponse(id: .number(1), result: .object(["ok": .bool(true)]))
        )
        let body = try JsonRpcCodec.encode(response)
        await server.respondWithJson(body)

        let transport = makeTransport()
        try await transport.send(frame(method: "tools/list", requestId: .number(1)))

        let received = try await firstInbound(transport: transport)
        XCTAssertEqual(try JsonRpcCodec.decode(received), response)
        await transport.close()
    }

    func testForwardedBytesAreNeverReEncoded() async throws {
        let body = Data(
            #"{"jsonrpc":"2.0","id":1,"result":{"exact":1.0,"huge":123456789012345678901}}"#.utf8
        )
        await server.respondWithJson(body)

        let transport = makeTransport()
        try await transport.send(frame(method: "tools/call", name: "x", requestId: .number(1)))

        let received = try await firstInbound(transport: transport)
        XCTAssertEqual(
            received,
            body,
            "A decode-and-re-encode round trip turns 1.0 into 1 and rounds the huge integer"
        )
        await transport.close()
    }

    func testSseFramesArriveInOrder() async throws {
        let progress = JsonRpcMessage.notification(
            JsonRpcNotification(method: "notifications/progress", params: .object(["progress": .double(0.5)]))
        )
        let completion = JsonRpcMessage.successResponse(
            JsonRpcSuccessResponse(id: .number(2), result: .object(["done": .bool(true)]))
        )
        let stream = try Self.sseBody([progress, completion])
        await server.setResponse(MockHttpResponse(
            status: 200,
            headers: [("Content-Type", "text/event-stream")],
            body: stream
        ))

        let transport = makeTransport()
        try await transport.send(frame(method: "tools/call", name: "run", requestId: .number(2)))

        let received = try await collectInbound(transport: transport, count: 2)
        XCTAssertEqual(try JsonRpcCodec.decode(received[0]), progress)
        XCTAssertEqual(try JsonRpcCodec.decode(received[1]), completion)
        await transport.close()
    }

    func testEveryRequestCarriesTheModernProtocolVersion() async throws {
        await server.respondWithJson(try Self.successBody(id: .number(1)))

        let transport = makeTransport()
        try await transport.send(frame(method: "tools/list", requestId: .number(1)))
        _ = try await firstInbound(transport: transport)

        let recorded = await server.requests
        let request = try XCTUnwrap(recorded.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.header("MCP-Protocol-Version"), MCPProtocolVersion.latest.rawValue)
        XCTAssertEqual(request.header("Mcp-Method"), "tools/list")
        XCTAssertEqual(request.header("Authorization"), "Bearer test-token")
        XCTAssertEqual(request.header("Content-Type"), "application/json")
        await transport.close()
    }

    func testTheBridgeNeverSendsASessionHeader() async throws {
        await server.setResponse(MockHttpResponse(
            status: 200,
            headers: [("Content-Type", "application/json"), ("Mcp-Session-Id", "server-minted")],
            body: try Self.successBody(id: .number(1))
        ))

        let transport = makeTransport()
        try await transport.send(frame(method: "tools/list", requestId: .number(1)))
        _ = try await firstInbound(transport: transport)

        try await transport.send(frame(method: "resources/list", requestId: .number(2)))
        _ = try await firstInbound(transport: transport)

        let requests = await server.requests
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertNil(request.header("Mcp-Session-Id"))
            XCTAssertNil(request.header("Last-Event-ID"))
        }
        await transport.close()
    }

    func testNamedMethodsCarryTheNameHeader() async throws {
        await server.respondWithJson(try Self.successBody(id: .number(1)))

        let transport = makeTransport()
        for method in ["tools/call", "resources/read", "prompts/get"] {
            try await transport.send(frame(method: method, name: "explain_table", requestId: .number(1)))
            _ = try await firstInbound(transport: transport)
        }

        let requests = await server.requests
        XCTAssertEqual(requests.count, 3)
        for request in requests {
            XCTAssertEqual(request.header("Mcp-Name"), "explain_table")
        }
        await transport.close()
    }

    func testAMethodThatIsNotNamedNeverCarriesTheNameHeader() async throws {
        await server.respondWithJson(try Self.successBody(id: .number(1)))

        let transport = makeTransport()
        try await transport.send(frame(method: "tools/list", name: "explain_table", requestId: .number(1)))
        _ = try await firstInbound(transport: transport)

        let recorded = await server.requests
        let request = try XCTUnwrap(recorded.first)
        XCTAssertNil(request.header("Mcp-Name"))
        await transport.close()
    }

    func testANameThatIsNotHeaderSafeIsBase64Wrapped() async throws {
        await server.respondWithJson(try Self.successBody(id: .number(1)))

        let transport = makeTransport()
        try await transport.send(frame(method: "tools/call", name: "café", requestId: .number(1)))
        _ = try await firstInbound(transport: transport)

        let recorded = await server.requests
        let request = try XCTUnwrap(recorded.first)
        let name = try XCTUnwrap(request.header("Mcp-Name"))
        XCTAssertTrue(MCPBase64Sentinel.isSentinel(name))
        XCTAssertEqual(MCPBase64Sentinel.decode(name), "café")
        await transport.close()
    }

    func testAMethodlessFrameCarriesNoMethodHeader() async throws {
        await server.respondWithJson(try Self.successBody(id: .number(1)))

        let transport = makeTransport()
        try await transport.send(MCPUpstreamFrame(body: Data("{}".utf8), requestId: .number(1)))
        _ = try await firstInbound(transport: transport)

        let recorded = await server.requests
        let request = try XCTUnwrap(recorded.first)
        XCTAssertNil(request.header("Mcp-Method"))
        await transport.close()
    }

    func testHttp404BecomesMethodNotFound() async throws {
        let error = try await errorForStatus(404, body: "no such method", method: "tools/list")
        XCTAssertEqual(error.error.code, JsonRpcErrorCode.methodNotFound)
        XCTAssertTrue(error.error.message.contains("tools/list"))
    }

    func testHttp403BecomesForbidden() async throws {
        let error = try await errorForStatus(403, body: "policy denied")
        XCTAssertEqual(error.error.code, JsonRpcErrorCode.forbidden)
    }

    func testHttp405BecomesMethodNotAllowed() async throws {
        let error = try await errorForStatus(405, body: "GET is not a thing here")
        XCTAssertEqual(error.error.code, JsonRpcErrorCode.invalidRequest)
    }

    func testHttp413BecomesPayloadTooLarge() async throws {
        let error = try await errorForStatus(413, body: "too big")
        XCTAssertEqual(error.error.code, JsonRpcErrorCode.tooLarge)
    }

    func testHttp429BecomesRateLimited() async throws {
        let error = try await errorForStatus(429, body: "slow down")
        XCTAssertEqual(error.error.code, JsonRpcErrorCode.rateLimited)
    }

    func testHttp503BecomesServiceUnavailable() async throws {
        let error = try await errorForStatus(503, body: "restarting")
        XCTAssertEqual(error.error.code, JsonRpcErrorCode.serverError)
    }

    func testHttp500BecomesInternalError() async throws {
        let error = try await errorForStatus(500, body: "kaboom")
        XCTAssertEqual(error.error.code, JsonRpcErrorCode.internalError)
    }

    func testAServerErrorEnvelopeIsForwardedUntouched() async throws {
        let envelope = JsonRpcMessage.errorResponse(
            JsonRpcErrorResponse(
                id: .number(8),
                error: JsonRpcError(code: JsonRpcErrorCode.forbidden, message: "policy denied")
            )
        )
        let body = try JsonRpcCodec.encode(envelope)
        await server.setResponse(MockHttpResponse(
            status: 403,
            headers: [("Content-Type", "application/json")],
            body: body
        ))

        let transport = makeTransport()
        try await transport.send(frame(method: "tools/call", name: "x", requestId: .number(8)))

        let received = try await firstInbound(transport: transport)
        XCTAssertEqual(received, body)
        await transport.close()
    }

    func testAnHttpFailureOnANotificationAnswersNobody() async throws {
        await server.setResponse(MockHttpResponse(
            status: 500,
            headers: [("Content-Type", "text/plain")],
            body: Data("kaboom".utf8)
        ))

        let transport = makeTransport()
        try await transport.send(MCPUpstreamFrame(
            body: Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled"}"#.utf8),
            method: "notifications/cancelled"
        ))

        let mock = server
        try await waitUntil { await mock?.requests.count == 1 }
        let inbound = try? await firstInbound(transport: transport, timeout: 0.4)
        XCTAssertNil(inbound, "A notification has no id, so there is nothing to answer")
        await transport.close()
    }

    func testUnauthorizedRefreshesCredentialsAndRetriesExactlyOnce() async throws {
        let refreshed = MCPUpstreamCredentials(
            endpoint: try endpoint(),
            bearerToken: "refreshed-token"
        )
        let provider = QueuedCredentialsProvider(
            initial: MCPUpstreamCredentials(endpoint: try endpoint(), bearerToken: "stale-token"),
            queued: [refreshed]
        )
        await server.setResponses([
            MockHttpResponse(status: 401, headers: [("Content-Type", "text/plain")], body: Data("nope".utf8)),
            MockHttpResponse(
                status: 200,
                headers: [("Content-Type", "application/json")],
                body: try Self.successBody(id: .number(3))
            )
        ])

        let transport = makeTransport(credentialsProvider: provider)
        try await transport.send(frame(method: "tools/list", requestId: .number(3)))

        let received = try await firstInbound(transport: transport)
        guard case .successResponse(let success) = try JsonRpcCodec.decode(received) else {
            XCTFail("Expected the retried request to succeed")
            return
        }
        XCTAssertEqual(success.id, .number(3))

        let requests = await server.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].header("Authorization"), "Bearer stale-token")
        XCTAssertEqual(requests[1].header("Authorization"), "Bearer refreshed-token")
        let refreshes = await provider.refreshCount
        XCTAssertEqual(refreshes, 1)
        await transport.close()
    }

    func testASecondUnauthorizedIsReportedRatherThanRetriedAgain() async throws {
        let provider = QueuedCredentialsProvider(
            initial: MCPUpstreamCredentials(endpoint: try endpoint(), bearerToken: "stale-token"),
            queued: [MCPUpstreamCredentials(endpoint: try endpoint(), bearerToken: "still-stale")]
        )
        await server.setResponse(MockHttpResponse(
            status: 401,
            headers: [("Content-Type", "text/plain")],
            body: Data("nope".utf8)
        ))

        let transport = makeTransport(credentialsProvider: provider)
        try await transport.send(frame(method: "tools/list", requestId: .number(4)))

        let received = try await firstInbound(transport: transport)
        guard case .errorResponse(let failure) = try JsonRpcCodec.decode(received) else {
            XCTFail("Expected an error response")
            return
        }
        XCTAssertEqual(failure.error.code, JsonRpcErrorCode.unauthenticated)

        let requests = await server.requests
        XCTAssertEqual(requests.count, 2, "The bridge retries once, never in a loop")
        let refreshes = await provider.refreshCount
        XCTAssertEqual(refreshes, 1)
        await transport.close()
    }

    func testAFailedRefreshSurfacesAnErrorRatherThanHanging() async throws {
        let provider = QueuedCredentialsProvider(
            initial: MCPUpstreamCredentials(endpoint: try endpoint(), bearerToken: "stale-token"),
            queued: []
        )
        await server.setResponse(MockHttpResponse(
            status: 401,
            headers: [("Content-Type", "text/plain")],
            body: Data("nope".utf8)
        ))

        let transport = makeTransport(credentialsProvider: provider)
        try await transport.send(frame(method: "tools/list", requestId: .number(5)))

        let received = try await firstInbound(transport: transport)
        guard case .errorResponse(let failure) = try JsonRpcCodec.decode(received) else {
            XCTFail("Expected an error response")
            return
        }
        XCTAssertEqual(failure.id, .number(5))
        await transport.close()
    }

    func testAnUnreachableEndpointTellsTheUserToStartTablePro() async throws {
        let credentials = MCPUpstreamCredentials(
            endpoint: try XCTUnwrap(URL(string: "http://127.0.0.1:1/mcp")),
            bearerToken: "token"
        )
        let transport = MCPStreamableHttpClientTransport(
            configuration: MCPStreamableHttpClientConfiguration(requestTimeout: .seconds(5)),
            credentialsProvider: MCPCachedUpstreamCredentialsProvider(initial: credentials) { credentials },
            errorLogger: nil
        )
        try await transport.send(frame(method: "tools/list", requestId: .number(6)))

        let received = try await firstInbound(transport: transport, timeout: 5.0)
        guard case .errorResponse(let failure) = try JsonRpcCodec.decode(received) else {
            XCTFail("Expected an error response")
            return
        }
        XCTAssertEqual(failure.error.code, JsonRpcErrorCode.serverError)
        XCTAssertTrue(failure.error.message.contains("TablePro"))
        await transport.close()
    }

    func testClosingSendsNoDeleteAndNoFurtherRequest() async throws {
        await server.respondWithJson(try Self.successBody(id: .number(1)))

        let transport = makeTransport()
        try await transport.send(frame(method: "tools/list", requestId: .number(1)))
        _ = try await firstInbound(transport: transport)

        await transport.close()
        try await Task.sleep(for: .milliseconds(200))

        let requests = await server.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertFalse(requests.contains { $0.method == "DELETE" })
    }

    func testClosingIsIdempotentAndSendingAfterwardsThrows() async throws {
        let transport = makeTransport()
        await transport.close()
        await transport.close()

        do {
            try await transport.send(frame(method: "tools/list", requestId: .number(1)))
            XCTFail("Expected a closed transport to refuse a send")
        } catch let error as MCPTransportError {
            XCTAssertEqual(error, .closed)
        }
    }

    func testClosingFinishesTheInboundStream() async throws {
        let transport = makeTransport()
        await transport.close()

        var iterator = transport.inbound.makeAsyncIterator()
        let next = try await iterator.next()
        XCTAssertNil(next)
    }

    private func errorForStatus(
        _ status: Int,
        body: String,
        method: String = "tools/call"
    ) async throws -> JsonRpcErrorResponse {
        await server.setResponse(MockHttpResponse(
            status: status,
            headers: [("Content-Type", "text/plain")],
            body: Data(body.utf8)
        ))

        let transport = makeTransport()
        try await transport.send(frame(method: method, name: "x", requestId: .number(11)))

        let received = try await firstInbound(transport: transport)
        await transport.close()

        guard case .errorResponse(let failure) = try JsonRpcCodec.decode(received) else {
            throw TransportTestError.unexpectedMessage
        }
        XCTAssertEqual(failure.id, .number(11))
        return failure
    }

    private func frame(
        method: String,
        name: String? = nil,
        requestId: JsonRpcId? = nil
    ) -> MCPUpstreamFrame {
        let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"\#(method)","params":{}}"#.utf8)
        return MCPUpstreamFrame(body: body, method: method, name: name, requestId: requestId)
    }

    private func endpoint() throws -> URL {
        try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/mcp"))
    }

    private func makeTransport(
        credentialsProvider: (any MCPUpstreamCredentialsProviding)? = nil
    ) -> MCPStreamableHttpClientTransport {
        let credentials = MCPUpstreamCredentials(
            endpoint: URL(string: "http://127.0.0.1:\(server.port)/mcp") ?? URL(fileURLWithPath: "/"),
            bearerToken: "test-token"
        )
        let provider = credentialsProvider
            ?? MCPCachedUpstreamCredentialsProvider(initial: credentials) { credentials }
        return MCPStreamableHttpClientTransport(
            configuration: MCPStreamableHttpClientConfiguration(requestTimeout: .seconds(5)),
            credentialsProvider: provider,
            errorLogger: nil
        )
    }

    private static func successBody(id: JsonRpcId) throws -> Data {
        try JsonRpcCodec.encode(
            .successResponse(JsonRpcSuccessResponse(id: id, result: .object(["ok": .bool(true)])))
        )
    }

    private static func sseBody(_ messages: [JsonRpcMessage]) throws -> Data {
        var text = ""
        for message in messages {
            let payload = try JsonRpcCodec.encode(message)
            text += "data: \(String(data: payload, encoding: .utf8) ?? "")\n\n"
        }
        return Data(text.utf8)
    }

    private func waitUntil(
        timeout: TimeInterval = 3.0,
        condition: @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TransportTestError.timeout
    }

    private func firstInbound(
        transport: MCPStreamableHttpClientTransport,
        timeout: TimeInterval = 3.0
    ) async throws -> Data {
        let collected = try await collectInbound(transport: transport, count: 1, timeout: timeout)
        guard let first = collected.first else { throw TransportTestError.timeout }
        return first
    }

    private func collectInbound(
        transport: MCPStreamableHttpClientTransport,
        count: Int,
        timeout: TimeInterval = 3.0
    ) async throws -> [Data] {
        try await withThrowingTaskGroup(of: [Data]?.self) { group in
            group.addTask {
                var iterator = transport.inbound.makeAsyncIterator()
                var collected: [Data] = []
                while collected.count < count {
                    guard let next = try await iterator.next() else { break }
                    collected.append(next)
                }
                return collected
            }
            group.addTask {
                try await Task.sleep(for: .milliseconds(Int(timeout * 1000)))
                return nil
            }
            guard let result = try await group.next(), let value = result, value.count == count else {
                group.cancelAll()
                throw TransportTestError.timeout
            }
            group.cancelAll()
            return value
        }
    }
}

enum TransportTestError: Error {
    case timeout
    case noQueuedCredentials
    case unexpectedMessage
}

actor QueuedCredentialsProvider: MCPUpstreamCredentialsProviding {
    private var current: MCPUpstreamCredentials
    private var queued: [MCPUpstreamCredentials]
    private(set) var refreshCount = 0

    init(initial: MCPUpstreamCredentials, queued: [MCPUpstreamCredentials]) {
        current = initial
        self.queued = queued
    }

    func currentCredentials() async -> MCPUpstreamCredentials {
        current
    }

    func refreshCredentials() async throws -> MCPUpstreamCredentials {
        refreshCount += 1
        guard !queued.isEmpty else { throw TransportTestError.noQueuedCredentials }
        current = queued.removeFirst()
        return current
    }
}

struct MockHttpRequest: Sendable {
    let method: String
    let path: String
    let headers: [(String, String)]
    let body: Data

    func header(_ name: String) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }
}

struct MockHttpResponse: Sendable {
    let status: Int
    let headers: [(String, String)]
    let body: Data
}

actor MockServerState {
    private(set) var requests: [MockHttpRequest] = []
    private var responses: [MockHttpResponse] = []

    func setResponses(_ responses: [MockHttpResponse]) {
        self.responses = responses
    }

    func record(_ request: MockHttpRequest) -> MockHttpResponse {
        requests.append(request)
        if responses.count > 1 {
            return responses.removeFirst()
        }
        guard let only = responses.first else {
            return MockHttpResponse(
                status: 500,
                headers: [("Content-Type", "text/plain")],
                body: Data("no response queued".utf8)
            )
        }
        return only
    }
}

final class MockHttpServer: @unchecked Sendable {
    private var listener: NWListener?
    private let state = MockServerState()
    private let lock = NSLock()
    private var assignedPort: UInt16 = 0
    private var connections: [NWConnection] = []

    var port: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return assignedPort
    }

    var requests: [MockHttpRequest] {
        get async { await state.requests }
    }

    func setResponse(_ response: MockHttpResponse) async {
        await state.setResponses([response])
    }

    func setResponses(_ responses: [MockHttpResponse]) async {
        await state.setResponses(responses)
    }

    func respondWithJson(_ body: Data) async {
        await setResponse(MockHttpResponse(
            status: 200,
            headers: [("Content-Type", "application/json")],
            body: body
        ))
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                let listener = try NWListener(using: parameters)
                lock.lock()
                self.listener = listener
                lock.unlock()

                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        if let port = listener.port?.rawValue {
                            self.lock.lock()
                            self.assignedPort = port
                            self.lock.unlock()
                        }
                        continuation.resume()
                    case .failed(let error):
                        continuation.resume(throwing: error)
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.handle(connection)
                }
                listener.start(queue: .global(qos: .userInitiated))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func stop() async {
        lock.lock()
        let listener = self.listener
        let connections = self.connections
        self.listener = nil
        self.connections = []
        lock.unlock()
        listener?.cancel()
        for connection in connections {
            connection.cancel()
        }
    }

    private func handle(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            guard case .ready = state else { return }
            self?.readRequest(connection: connection, accumulated: Data())
        }
        connection.start(queue: .global(qos: .userInitiated))
    }

    private func readRequest(connection: NWConnection, accumulated: Data) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }
            var buffer = accumulated
            if let data {
                buffer.append(data)
            }

            if let request = Self.parseRequest(buffer) {
                Task {
                    let response = await self.state.record(request)
                    connection.send(
                        content: Self.serializeResponse(response),
                        completion: .contentProcessed { _ in connection.cancel() }
                    )
                }
                return
            }

            if isComplete {
                connection.cancel()
                return
            }
            self.readRequest(connection: connection, accumulated: buffer)
        }
    }

    private static func parseRequest(_ data: Data) -> MockHttpRequest? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data[..<separator.lowerBound]
        let bodyStart = separator.upperBound
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 3 else { return nil }

        var headers: [(String, String)] = []
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex ..< colon])
            var rest = line[line.index(after: colon)...]
            if rest.first == " " {
                rest = rest.dropFirst()
            }
            headers.append((key, String(rest)))
        }

        var contentLength = 0
        if let raw = headers.first(where: { $0.0.lowercased() == "content-length" })?.1,
           let parsed = Int(raw) {
            contentLength = parsed
        }

        let body: Data
        if contentLength > 0 {
            guard data.count - bodyStart >= contentLength else { return nil }
            body = data.subdata(in: bodyStart ..< (bodyStart + contentLength))
        } else {
            body = Data()
        }

        return MockHttpRequest(
            method: String(parts[0]),
            path: String(parts[1]),
            headers: headers,
            body: body
        )
    }

    private static func serializeResponse(_ response: MockHttpResponse) -> Data {
        var output = "HTTP/1.1 \(response.status) \(reasonPhrase(for: response.status))\r\n"
        var headers = response.headers
        if !headers.contains(where: { $0.0.lowercased() == "content-length" }) {
            headers.append(("Content-Length", "\(response.body.count)"))
        }
        if !headers.contains(where: { $0.0.lowercased() == "connection" }) {
            headers.append(("Connection", "close"))
        }
        for (key, value) in headers {
            output.append("\(key): \(value)\r\n")
        }
        output.append("\r\n")
        var data = Data(output.utf8)
        data.append(response.body)
        return data
    }

    private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}
