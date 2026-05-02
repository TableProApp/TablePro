import Foundation
import Network
@testable import TablePro
import XCTest

final class MCPBridgeIntegrationTests: XCTestCase {
    fileprivate static let mcpVersion = "2024-11-05"
    fileprivate static let bearerToken = "integration-token"

    func testHappyPathInitializeAndToolsListFlowsThroughBridge() async throws {
        let harness = try await BridgeHarness.start(authenticator: StubAlwaysAllowAuthenticator())
        defer { harness.shutdown() }

        let consumer = StubExchangeConsumer()
        await consumer.start(transport: harness.serverTransport) { exchange in
            switch exchange.message {
            case .request(let request):
                let response = JsonRpcMessage.successResponse(
                    JsonRpcSuccessResponse(
                        id: request.id,
                        result: .object(["echo": .string(request.method)])
                    )
                )
                await exchange.responder.respond(response, sessionId: exchange.context.sessionId)
            default:
                await exchange.responder.respondError(.invalidRequest(detail: "unsupported"), requestId: nil)
            }
        }
        defer { Task { await consumer.stop() } }

        let initRequest = JsonRpcMessage.request(
            JsonRpcRequest(id: .number(1), method: "initialize", params: nil)
        )
        try await harness.writeFromHost(initRequest)

        let firstResponse = try await harness.readNextResponse()
        guard case .successResponse(let success) = firstResponse else {
            XCTFail("Expected successResponse for initialize, got \(firstResponse)")
            return
        }
        XCTAssertEqual(success.id, .number(1))
        XCTAssertEqual(success.result["echo"]?.stringValue, "initialize")

        let toolsRequest = JsonRpcMessage.request(
            JsonRpcRequest(id: .number(2), method: "tools/list", params: nil)
        )
        try await harness.writeFromHost(toolsRequest)

        let secondResponse = try await harness.readNextResponse()
        guard case .successResponse(let toolsSuccess) = secondResponse else {
            XCTFail("Expected successResponse for tools/list, got \(secondResponse)")
            return
        }
        XCTAssertEqual(toolsSuccess.id, .number(2))
        XCTAssertEqual(toolsSuccess.result["echo"]?.stringValue, "tools/list")
    }

    func testIdleSessionEvictionReturnsSessionNotFoundError() async throws {
        let clock = MCPTestClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let policy = MCPSessionPolicy(
            idleTimeout: .seconds(60),
            maxSessions: 16,
            cleanupInterval: .seconds(60)
        )
        let harness = try await BridgeHarness.start(
            authenticator: StubAlwaysAllowAuthenticator(),
            clock: clock,
            sessionPolicy: policy
        )
        defer { harness.shutdown() }

        let consumer = StubExchangeConsumer()
        await consumer.start(transport: harness.serverTransport) { exchange in
            switch exchange.message {
            case .request(let request):
                let response = JsonRpcMessage.successResponse(
                    JsonRpcSuccessResponse(id: request.id, result: .object(["ok": .bool(true)]))
                )
                await exchange.responder.respond(response, sessionId: exchange.context.sessionId)
            default:
                await exchange.responder.respondError(.invalidRequest(detail: "unsupported"), requestId: nil)
            }
        }
        defer { Task { await consumer.stop() } }

        let initRequest = JsonRpcMessage.request(
            JsonRpcRequest(id: .number(10), method: "initialize", params: nil)
        )
        try await harness.writeFromHost(initRequest)

        let initResponse = try await harness.readNextResponse()
        guard case .successResponse = initResponse else {
            XCTFail("Expected initialize success, got \(initResponse)")
            return
        }
        let initialSessionCount = await harness.sessionStore.count()
        XCTAssertEqual(initialSessionCount, 1)

        await clock.advance(by: .seconds(120))
        await harness.sessionStore.runCleanupPass()
        let postCleanupCount = await harness.sessionStore.count()
        XCTAssertEqual(postCleanupCount, 0)

        let followUp = JsonRpcMessage.request(
            JsonRpcRequest(id: .number(11), method: "tools/call", params: nil)
        )
        try await harness.writeFromHost(followUp)

        let response = try await harness.readNextResponse()
        guard case .errorResponse(let envelope) = response else {
            XCTFail("Expected errorResponse, got \(response)")
            return
        }
        XCTAssertEqual(envelope.id, .number(11))
        XCTAssertEqual(envelope.error.code, JsonRpcErrorCode.sessionNotFound)
    }

    func testServerReturning404WithGarbageBodyIsWrappedAsJsonRpcError() async throws {
        let badServer = try await BadHttpServer.start { _ in
            BadHttpResponse(
                status: 404,
                headers: [("Content-Type", "application/json")],
                body: Data("{\"error\":\"Session not found\"}".utf8)
            )
        }
        defer { badServer.stop() }

        guard let url = URL(string: "http://127.0.0.1:\(badServer.port)/mcp") else {
            XCTFail("Failed to build URL")
            return
        }
        let configuration = MCPStreamableHttpClientConfiguration(
            endpoint: url,
            bearerToken: Self.bearerToken,
            tlsCertFingerprint: nil,
            requestTimeout: .seconds(5),
            serverInitiatedStream: false
        )
        let client = MCPStreamableHttpClientTransport(configuration: configuration, errorLogger: nil)
        defer { Task { await client.close() } }

        let request = JsonRpcMessage.request(
            JsonRpcRequest(id: .number(42), method: "tools/list", params: nil)
        )
        try await client.send(request)

        let received = try await Self.firstInbound(of: client, timeout: 3.0)
        guard case .errorResponse(let envelope) = received else {
            XCTFail("Expected errorResponse, got \(received)")
            return
        }
        XCTAssertEqual(envelope.id, .number(42))
        XCTAssertEqual(envelope.error.code, JsonRpcErrorCode.sessionNotFound)

        let encoded = try JsonRpcCodec.encode(received)
        let roundTripped = try JsonRpcCodec.decode(encoded)
        XCTAssertEqual(roundTripped, received)
    }

    func testMalformedRequestReturnsValidJsonRpcErrorEnvelope() async throws {
        let harness = try await BridgeHarness.start(authenticator: StubAlwaysAllowAuthenticator())
        defer { harness.shutdown() }

        let consumer = StubExchangeConsumer()
        await consumer.start(transport: harness.serverTransport) { exchange in
            await exchange.responder.respondError(.invalidRequest(detail: "should-not-reach"), requestId: nil)
        }
        defer { Task { await consumer.stop() } }

        guard let url = URL(string: "http://127.0.0.1:\(harness.serverPort)/mcp") else {
            XCTFail("Failed to build URL")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.mcpVersion, forHTTPHeaderField: "mcp-protocol-version")
        request.setValue("Bearer \(Self.bearerToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("{\"not\":\"json-rpc\"}".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertGreaterThanOrEqual(httpResponse.statusCode, 400)
        XCTAssertLessThan(httpResponse.statusCode, 500)
        XCTAssertFalse(data.isEmpty, "Server must return a body for malformed requests")

        let decoded = try JsonRpcCodec.decode(data)
        guard case .errorResponse(let envelope) = decoded else {
            XCTFail("Expected JSON-RPC errorResponse envelope, got \(decoded)")
            return
        }
        XCTAssertTrue(
            envelope.error.code == JsonRpcErrorCode.invalidRequest
                || envelope.error.code == JsonRpcErrorCode.parseError
                || envelope.error.code == JsonRpcErrorCode.methodNotFound,
            "Unexpected error code \(envelope.error.code)"
        )

        let plainErrorShape = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let asObject = plainErrorShape {
            XCTAssertNotNil(asObject["jsonrpc"], "Body must include jsonrpc field; got plain dict \(asObject)")
            XCTAssertNotNil(asObject["error"], "Body must include error field")
        }
    }

    private static func firstInbound(
        of transport: MCPStreamableHttpClientTransport,
        timeout: TimeInterval
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
                throw IntegrationTestError.timeout
            }
            group.cancelAll()
            return value
        }
    }
}

private enum IntegrationTestError: Error {
    case timeout
    case serverDidNotStart
    case readClosed
}

private struct PipePair {
    let hostInput: FileHandle
    let bridgeStdin: FileHandle
    let bridgeStdout: FileHandle
    let hostOutput: FileHandle

    let stdinPipe: Pipe
    let stdoutPipe: Pipe

    static func make() -> PipePair {
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        return PipePair(
            hostInput: stdinPipe.fileHandleForWriting,
            bridgeStdin: stdinPipe.fileHandleForReading,
            bridgeStdout: stdoutPipe.fileHandleForWriting,
            hostOutput: stdoutPipe.fileHandleForReading,
            stdinPipe: stdinPipe,
            stdoutPipe: stdoutPipe
        )
    }

    func closeAll() {
        try? hostInput.close()
        try? bridgeStdin.close()
        try? bridgeStdout.close()
        try? hostOutput.close()
    }
}

private final class IntegrationBridgeLogger: MCPBridgeLogger, @unchecked Sendable {
    func log(_ level: MCPBridgeLogLevel, _ message: String) {}
}

private actor TestBridgeProxy {
    private let host: any MCPMessageTransport
    private let upstream: any MCPMessageTransport
    private let logger: any MCPBridgeLogger
    private var task: Task<Void, Never>?

    init(host: any MCPMessageTransport, upstream: any MCPMessageTransport, logger: any MCPBridgeLogger) {
        self.host = host
        self.upstream = upstream
        self.logger = logger
    }

    func start() {
        task = Task { [host, upstream, logger] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await Self.forward(from: host, to: upstream, direction: "host→upstream", logger: logger)
                }
                group.addTask {
                    await Self.forward(from: upstream, to: host, direction: "upstream→host", logger: logger)
                }
                await group.waitForAll()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private static func forward(
        from source: any MCPMessageTransport,
        to destination: any MCPMessageTransport,
        direction: String,
        logger: any MCPBridgeLogger
    ) async {
        do {
            for try await message in source.inbound {
                do {
                    try await destination.send(message)
                } catch {
                    logger.log(.warning, "[\(direction)] send failed: \(error.localizedDescription)")
                }
            }
            logger.log(.info, "[\(direction)] inbound stream closed")
        } catch {
            logger.log(.error, "[\(direction)] inbound failed: \(error.localizedDescription)")
        }
        await destination.close()
    }
}

private actor LineQueue {
    private var pending: [Data] = []
    private var waiters: [CheckedContinuation<Data?, Never>] = []
    private var finished = false

    func push(_ line: Data) {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: line)
            return
        }
        pending.append(line)
    }

    func finish() {
        finished = true
        let toResume = waiters
        waiters.removeAll()
        for waiter in toResume {
            waiter.resume(returning: nil)
        }
    }

    func next() async -> Data? {
        if !pending.isEmpty {
            return pending.removeFirst()
        }
        if finished {
            return nil
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private final class BridgeHarness: @unchecked Sendable {
    let serverTransport: MCPHttpServerTransport
    let sessionStore: MCPSessionStore
    let serverPort: UInt16
    let clientTransport: MCPStreamableHttpClientTransport
    let stdioTransport: MCPStdioMessageTransport
    private let proxy: TestBridgeProxy
    private let pipes: PipePair
    private let lineQueue = LineQueue()
    private var readerTask: Task<Void, Never>?
    private let stateLock = NSLock()

    private init(
        serverTransport: MCPHttpServerTransport,
        sessionStore: MCPSessionStore,
        serverPort: UInt16,
        clientTransport: MCPStreamableHttpClientTransport,
        stdioTransport: MCPStdioMessageTransport,
        proxy: TestBridgeProxy,
        pipes: PipePair
    ) {
        self.serverTransport = serverTransport
        self.sessionStore = sessionStore
        self.serverPort = serverPort
        self.clientTransport = clientTransport
        self.stdioTransport = stdioTransport
        self.proxy = proxy
        self.pipes = pipes
    }

    static func start(
        authenticator: any MCPAuthenticator,
        clock: any MCPClock = MCPSystemClock(),
        sessionPolicy: MCPSessionPolicy = MCPSessionPolicy(
            idleTimeout: .seconds(900),
            maxSessions: 16,
            cleanupInterval: .seconds(60)
        )
    ) async throws -> BridgeHarness {
        let store = MCPSessionStore(policy: sessionPolicy, clock: clock)
        let configuration = MCPHttpServerConfiguration.loopback(port: 0)
        let serverTransport = MCPHttpServerTransport(
            configuration: configuration,
            sessionStore: store,
            authenticator: authenticator,
            clock: clock
        )

        let stateStream = serverTransport.listenerState
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

        try await serverTransport.start()
        guard let port = await stateTask.value, port != 0 else {
            await serverTransport.stop()
            throw IntegrationTestError.serverDidNotStart
        }

        guard let url = URL(string: "http://127.0.0.1:\(port)/mcp") else {
            await serverTransport.stop()
            throw IntegrationTestError.serverDidNotStart
        }
        let logger = IntegrationBridgeLogger()
        let clientConfig = MCPStreamableHttpClientConfiguration(
            endpoint: url,
            bearerToken: MCPBridgeIntegrationTests.bearerToken,
            tlsCertFingerprint: nil,
            requestTimeout: .seconds(5),
            serverInitiatedStream: false
        )
        let clientTransport = MCPStreamableHttpClientTransport(
            configuration: clientConfig,
            errorLogger: logger
        )

        let pipes = PipePair.make()
        let stdioTransport = MCPStdioMessageTransport(
            stdin: pipes.bridgeStdin,
            stdout: pipes.bridgeStdout,
            errorLogger: logger
        )

        let proxy = TestBridgeProxy(host: stdioTransport, upstream: clientTransport, logger: logger)
        await proxy.start()

        let harness = BridgeHarness(
            serverTransport: serverTransport,
            sessionStore: store,
            serverPort: port,
            clientTransport: clientTransport,
            stdioTransport: stdioTransport,
            proxy: proxy,
            pipes: pipes
        )
        harness.startReader()
        return harness
    }

    func writeFromHost(_ message: JsonRpcMessage) async throws {
        let line = try JsonRpcCodec.encodeLine(message)
        try pipes.hostInput.write(contentsOf: line)
    }

    func readNextResponse(timeout: TimeInterval = 4.0) async throws -> JsonRpcMessage {
        let line = try await readNextLine(timeout: timeout)
        return try JsonRpcCodec.decode(line)
    }

    private func readNextLine(timeout: TimeInterval) async throws -> Data {
        let queue = lineQueue
        return try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask {
                await queue.next()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            guard let first = try await group.next(), let value = first else {
                group.cancelAll()
                throw IntegrationTestError.timeout
            }
            group.cancelAll()
            return value
        }
    }

    fileprivate func startReader() {
        stateLock.lock()
        if readerTask != nil {
            stateLock.unlock()
            return
        }
        let handle = pipes.hostOutput
        let queue = lineQueue
        readerTask = Task.detached(priority: .userInitiated) {
            var buffer = Data()
            do {
                for try await byte in handle.bytes {
                    if Task.isCancelled { return }
                    if byte == 0x0A {
                        var line = buffer
                        buffer.removeAll(keepingCapacity: true)
                        if line.last == 0x0D {
                            line.removeLast()
                        }
                        if !line.isEmpty {
                            await queue.push(line)
                        }
                    } else {
                        buffer.append(byte)
                    }
                }
            } catch {
                // pipe closed or read error; finish the queue
            }
            await queue.finish()
        }
        stateLock.unlock()
    }

    func shutdown() {
        stateLock.lock()
        readerTask?.cancel()
        readerTask = nil
        stateLock.unlock()
        let queue = lineQueue
        Task { await queue.finish() }
        Task { await proxy.stop() }
        Task { await stdioTransport.close() }
        Task { await clientTransport.close() }
        Task { await serverTransport.stop() }
        pipes.closeAll()
    }
}

private struct BadHttpResponse: Sendable {
    let status: Int
    let headers: [(String, String)]
    let body: Data
}

private actor BadHttpServerState {
    var responder: (@Sendable (Data) -> BadHttpResponse)?

    func setResponder(_ responder: @escaping @Sendable (Data) -> BadHttpResponse) {
        self.responder = responder
    }

    func respond(_ data: Data) -> BadHttpResponse {
        responder?(data) ?? BadHttpResponse(status: 500, headers: [], body: Data())
    }
}

private final class BadHttpServer: @unchecked Sendable {
    private let state = BadHttpServerState()
    private var listener: NWListener?
    private let lock = NSLock()
    private var assignedPort: UInt16 = 0
    private var connections: [NWConnection] = []

    var port: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return assignedPort
    }

    static func start(_ responder: @escaping @Sendable (Data) -> BadHttpResponse) async throws -> BadHttpServer {
        let server = BadHttpServer()
        await server.state.setResponder(responder)
        try await server.startListener()
        return server
    }

    private func startListener() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                let listener = try NWListener(using: params)
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

    func stop() {
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
                self?.readLoop(connection: connection, accumulated: Data())
            case .failed, .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }

    private func readLoop(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, isComplete, _ in
            guard let self else { return }
            var buffer = accumulated
            if let data {
                buffer.append(data)
            }

            if let bodyStart = Self.findHeaderEnd(buffer) {
                let contentLength = Self.contentLength(buffer.prefix(bodyStart))
                let bodyAvailable = buffer.count - bodyStart
                if bodyAvailable < contentLength {
                    if isComplete {
                        connection.cancel()
                        return
                    }
                    self.readLoop(connection: connection, accumulated: buffer)
                    return
                }
                let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
                Task {
                    let response = await self.state.respond(body)
                    let raw = Self.serialize(response)
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
            self.readLoop(connection: connection, accumulated: buffer)
        }
    }

    private static func findHeaderEnd(_ data: Data) -> Int? {
        guard let range = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        return range.upperBound
    }

    private static func contentLength(_ headerData: Data) -> Int {
        guard let headerString = String(data: headerData, encoding: .utf8) else { return 0 }
        for line in headerString.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].lowercased()
            if key == "content-length" {
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                return Int(value) ?? 0
            }
        }
        return 0
    }

    private static func serialize(_ response: BadHttpResponse) -> Data {
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
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}
