import Foundation
import TableProPluginKit
import Network
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
        await server.setResponder { _ in
            MockHttpResponse(status: 200, headers: [("Content-Type", "application/json")], body: body)
        }

        let transport = makeTransport()
        let request = JsonRpcMessage.request(
            JsonRpcRequest(id: .number(1), method: "ping", params: nil)
        )
        try await transport.send(request)

        let received = try await firstInbound(transport: transport)
        XCTAssertEqual(received, response)
        await transport.close()
    }

    func testSseResponseDeliversFramesIncrementally() async throws {
        let frame1 = JsonRpcMessage.notification(
            JsonRpcNotification(method: "notifications/progress", params: .object(["progress": .int(50)]))
        )
        let frame2 = JsonRpcMessage.successResponse(
            JsonRpcSuccessResponse(id: .number(2), result: .object(["done": .bool(true)]))
        )
        let payload1 = try JsonRpcCodec.encode(frame1)
        let payload2 = try JsonRpcCodec.encode(frame2)
        let body1 = "data: \(String(data: payload1, encoding: .utf8) ?? "")\n\n"
        let body2 = "data: \(String(data: payload2, encoding: .utf8) ?? "")\n\n"

        await server.setResponder { _ in
            MockHttpResponse(
                status: 200,
                headers: [("Content-Type", "text/event-stream")],
                body: Data((body1 + body2).utf8)
            )
        }

        let transport = makeTransport()
        let request = JsonRpcMessage.request(
            JsonRpcRequest(id: .number(2), method: "tools/run", params: nil)
        )
        try await transport.send(request)

        let received = try await collectInbound(transport: transport, count: 2)
        XCTAssertEqual(received[0], frame1)
        XCTAssertEqual(received[1], frame2)
        await transport.close()
    }

    func testHttp404SynthesizesSessionNotFoundError() async throws {
        await server.setResponder { _ in
            MockHttpResponse(
                status: 404,
                headers: [("Content-Type", "text/plain")],
                body: Data("Session not found".utf8)
            )
        }

        let transport = makeTransport()
        let request = JsonRpcMessage.request(
            JsonRpcRequest(id: .number(7), method: "tools/list", params: nil)
        )
        try await transport.send(request)

        let received = try await firstInbound(transport: transport)
        guard case .errorResponse(let response) = received else {
            XCTFail("Expected errorResponse, got \(received)")
            return
        }
        XCTAssertEqual(response.id, .number(7))
        XCTAssertEqual(response.error.code, JsonRpcErrorCode.sessionNotFound)
        await transport.close()
    }

    func testHttp401IncludesUnauthenticatedError() async throws {
        await server.setResponder { _ in
            MockHttpResponse(
                status: 401,
                headers: [
                    ("Content-Type", "text/plain"),
                    ("WWW-Authenticate", "Bearer realm=\"TablePro\"")
                ],
                body: Data("Unauthenticated".utf8)
            )
        }

        let transport = makeTransport()
        let request = JsonRpcMessage.request(
            JsonRpcRequest(id: .number(99), method: "tools/list", params: nil)
        )
        try await transport.send(request)

        let received = try await firstInbound(transport: transport)
        guard case .errorResponse(let response) = received else {
            XCTFail("Expected errorResponse, got \(received)")
            return
        }
        XCTAssertEqual(response.id, .number(99))
        XCTAssertEqual(response.error.code, JsonRpcErrorCode.unauthenticated)
        XCTAssertEqual(response.error.message, "Unauthenticated")
        await transport.close()
    }

    func testHttp500ProducesInternalError() async throws {
        await server.setResponder { _ in
            MockHttpResponse(
                status: 500,
                headers: [("Content-Type", "text/plain")],
                body: Data("kaboom".utf8)
            )
        }

        let transport = makeTransport()
        let request = JsonRpcMessage.request(
            JsonRpcRequest(id: .number(5), method: "x", params: nil)
        )
        try await transport.send(request)

        let received = try await firstInbound(transport: transport)
        guard case .errorResponse(let response) = received else {
            XCTFail("Expected errorResponse, got \(received)")
            return
        }
        XCTAssertEqual(response.id, .number(5))
        XCTAssertEqual(response.error.code, JsonRpcErrorCode.internalError)
        await transport.close()
    }

    func testServerEmittedJsonRpcErrorIsForwarded() async throws {
        let serverError = JsonRpcMessage.errorResponse(
            JsonRpcErrorResponse(
                id: .number(8),
                error: JsonRpcError(code: -32_007, message: "policy denied")
            )
        )
        let body = try JsonRpcCodec.encode(serverError)
        await server.setResponder { _ in
            MockHttpResponse(
                status: 403,
                headers: [("Content-Type", "application/json")],
                body: body
            )
        }

        let transport = makeTransport()
        let request = JsonRpcMessage.request(
            JsonRpcRequest(id: .number(8), method: "x", params: nil)
        )
        try await transport.send(request)

        let received = try await firstInbound(transport: transport)
        guard case .errorResponse(let response) = received else {
            XCTFail("Expected errorResponse")
            return
        }
        XCTAssertEqual(response.error.code, -32_007)
        XCTAssertEqual(response.error.message, "policy denied")
        await transport.close()
    }

    func testCapturesSessionIdFromResponse() async throws {
        let response = JsonRpcMessage.successResponse(
            JsonRpcSuccessResponse(id: .number(1), result: .object(["ok": .bool(true)]))
        )
        let body = try JsonRpcCodec.encode(response)
        await server.setResponder { _ in
            MockHttpResponse(
                status: 200,
                headers: [
                    ("Content-Type", "application/json"),
                    ("Mcp-Session-Id", "session-xyz")
                ],
                body: body
            )
        }

        let transport = makeTransport()
        try await transport.send(JsonRpcMessage.request(
            JsonRpcRequest(id: .number(1), method: "initialize", params: nil)
        ))
        _ = try await firstInbound(transport: transport)

        await server.setResponder { received in
            let sessionHeader = received.headers.first { $0.0.lowercased() == "mcp-session-id" }?.1
            let resultBody = try? JsonRpcCodec.encode(.successResponse(
                JsonRpcSuccessResponse(
                    id: .number(2),
                    result: .object(["session": .string(sessionHeader ?? "")])
                )
            ))
            return MockHttpResponse(
                status: 200,
                headers: [("Content-Type", "application/json")],
                body: resultBody ?? Data()
            )
        }

        try await transport.send(JsonRpcMessage.request(
            JsonRpcRequest(id: .number(2), method: "tools/list", params: nil)
        ))
        let second = try await firstInbound(transport: transport)
        guard case .successResponse(let success) = second else {
            XCTFail("Expected successResponse")
            return
        }
        XCTAssertEqual(success.result["session"]?.stringValue, "session-xyz")

        await transport.close()
    }

    private func makeTransport() -> MCPStreamableHttpClientTransport {
        let url = URL(string: "http://127.0.0.1:\(server.port)/mcp")!
        let configuration = MCPStreamableHttpClientConfiguration(
            endpoint: url,
            bearerToken: "test-token",
            tlsCertFingerprint: nil,
            requestTimeout: .seconds(5),
            serverInitiatedStream: false
        )
        return MCPStreamableHttpClientTransport(configuration: configuration, errorLogger: nil)
    }

    private func firstInbound(
        transport: MCPStreamableHttpClientTransport,
        timeout: TimeInterval = 3.0
    ) async throws -> JsonRpcMessage {
        try await withThrowingTaskGroup(of: JsonRpcMessage?.self) { group in
            group.addTask {
                var iterator = transport.inbound.makeAsyncIterator()
                return try await iterator.next()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            guard let result = try await group.next(), let value = result else {
                group.cancelAll()
                throw TransportTestError.timeout
            }
            group.cancelAll()
            return value
        }
    }

    private func collectInbound(
        transport: MCPStreamableHttpClientTransport,
        count: Int,
        timeout: TimeInterval = 3.0
    ) async throws -> [JsonRpcMessage] {
        try await withThrowingTaskGroup(of: [JsonRpcMessage]?.self) { group in
            group.addTask {
                var iterator = transport.inbound.makeAsyncIterator()
                var collected: [JsonRpcMessage] = []
                while collected.count < count {
                    guard let next = try await iterator.next() else { break }
                    collected.append(next)
                }
                return collected
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            guard let result = try await group.next(), let value = result else {
                group.cancelAll()
                throw TransportTestError.timeout
            }
            group.cancelAll()
            return value
        }
    }
}

private enum TransportTestError: Error {
    case timeout
}

private struct MockHttpRequest: Sendable {
    let method: String
    let path: String
    let headers: [(String, String)]
    let body: Data
}

private struct MockHttpResponse: Sendable {
    let status: Int
    let headers: [(String, String)]
    let body: Data
}

private actor MockServerState {
    var responder: (@Sendable (MockHttpRequest) -> MockHttpResponse)?

    func setResponder(_ responder: @escaping @Sendable (MockHttpRequest) -> MockHttpResponse) {
        self.responder = responder
    }

    func respond(to request: MockHttpRequest) -> MockHttpResponse {
        if let responder {
            return responder(request)
        }
        return MockHttpResponse(
            status: 500,
            headers: [("Content-Type", "text/plain")],
            body: Data("no responder".utf8)
        )
    }
}

private final class MockHttpServer: @unchecked Sendable {
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

    func setResponder(_ responder: @escaping @Sendable (MockHttpRequest) -> MockHttpResponse) async {
        await state.setResponder(responder)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                let listener = try NWListener(using: params)
                lock.lock()
                self.listener = listener
                lock.unlock()

                let port = self.port
                _ = port

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
            switch state {
            case .ready:
                self?.readRequest(connection: connection, accumulated: Data())
            case .failed, .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }

    private func readRequest(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                _ = error
                connection.cancel()
                return
            }
            var buffer = accumulated
            if let data {
                buffer.append(data)
            }

            if let request = Self.parseRequest(buffer) {
                Task {
                    let response = await self.state.respond(to: request)
                    let raw = Self.serializeResponse(response)
                    connection.send(content: raw, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
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
        guard let separatorRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }
        let headerData = data[..<separatorRange.lowerBound]
        let bodyStart = separatorRange.upperBound
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 3 else { return nil }
        let method = String(parts[0])
        let path = String(parts[1])

        var headers: [(String, String)] = []
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon])
            var rest = line[line.index(after: colon)...]
            if rest.first == " " {
                rest = rest.dropFirst()
            }
            headers.append((key, String(rest)))
        }

        var contentLength = 0
        if let value = headers.first(where: { $0.0.lowercased() == "content-length" })?.1,
           let parsed = Int(value) {
            contentLength = parsed
        }

        let body: Data
        if contentLength > 0 {
            let remaining = data.count - bodyStart
            if remaining < contentLength {
                return nil
            }
            body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        } else {
            body = Data()
        }

        return MockHttpRequest(method: method, path: path, headers: headers, body: body)
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
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}
