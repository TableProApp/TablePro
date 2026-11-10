import Darwin
import Foundation

public struct MCPSocketHttpRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [(String, String)]
    public let body: Data

    public init(method: String = "POST", path: String, headers: [(String, String)], body: Data) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

public struct MCPSocketHttpResponse: Sendable {
    public let status: Int
    public let headers: HttpHeaders
    public let body: AsyncThrowingStream<Data, Error>

    public func collectBody() async throws -> Data {
        var collected = Data()
        for try await chunk in body {
            collected.append(chunk)
        }
        return collected
    }
}

public enum MCPSocketHttpError: Error, Equatable, Sendable {
    // Nothing was sent, so the request can go out again once the listener is verified.
    case connectFailed(String)
    case invalidSocketPath(String)
    case invalidHeader(String)
    case peerChanged
    case timedOut
    case connectionClosed(String)
    case malformedResponse(String)
}

// URLSession has no Unix socket transport.
public enum MCPUnixSocketHttpClient {
    // The server's loopback Host check accepts a bare `localhost`; a socket has no port.
    public static let host = "localhost"

    public static func send(
        _ request: MCPSocketHttpRequest,
        socketPath: String,
        expectedPID: Int32,
        idleTimeout: Duration
    ) async throws -> MCPSocketHttpResponse {
        guard socketPath.hasPrefix("/"), MCPSocketLocation.fits(socketPath) else {
            throw MCPSocketHttpError.invalidSocketPath(socketPath)
        }
        let exchange = MCPUnixSocketHttpExchange(
            socketPath: socketPath,
            expectedPID: expectedPID,
            request: try encode(request),
            idleTimeout: idleTimeout
        )
        return try await exchange.run()
    }

    static func encode(_ request: MCPSocketHttpRequest) throws -> Data {
        var text = "\(request.method) \(request.path) HTTP/1.1\r\nHost: \(host)\r\n"
        for (name, value) in request.headers {
            guard isToken(name), isHeaderSafe(value) else {
                throw MCPSocketHttpError.invalidHeader(name)
            }
            text += "\(name): \(value)\r\n"
        }
        text += "Content-Length: \(request.body.count)\r\nConnection: close\r\n\r\n"
        var data = Data(text.utf8)
        data.append(request.body)
        return data
    }

    private static func isToken(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "!#$%&'*+-.^_`|~".unicodeScalars.contains(scalar))
        }
    }

    private static func isHeaderSafe(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            scalar.value == 0x09 || (0x20...0x7E).contains(scalar.value)
        }
    }
}

// The connection's handlers keep it alive until cancel; its state is touched on `queue` only.
private final class MCPUnixSocketHttpExchange: @unchecked Sendable {
    private static let receiveChunkSize = 65_536

    private let socketPath: String
    private let expectedPID: Int32
    private var connection: MCPUnixSocketConnection?
    private var connecting: DispatchSourceWrite?
    private var connected = false
    private let queue = DispatchQueue(label: "com.TablePro.MCP.UnixSocketHttpClient")
    private let request: Data
    private let idleTimeout: Duration
    private let bodyContinuation: AsyncThrowingStream<Data, Error>.Continuation
    // Handed to the response, so a response nobody reads ends the stream and closes the connection.
    private var body: AsyncThrowingStream<Data, Error>?

    private var reader = HttpResponseReader()
    private var headContinuation: CheckedContinuation<MCPSocketHttpResponse, Error>?
    private var headResolved = false
    private var finished = false
    private var idleTimer: DispatchSourceTimer?

    init(socketPath: String, expectedPID: Int32, request: Data, idleTimeout: Duration) {
        self.socketPath = socketPath
        self.expectedPID = expectedPID
        self.request = request
        self.idleTimeout = idleTimeout
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        body = stream
        bodyContinuation = continuation
    }

    func run() async throws -> MCPSocketHttpResponse {
        bodyContinuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            self?.cancel()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { self.begin(continuation) }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        queue.async { self.fail(CancellationError()) }
    }

    private func begin(_ continuation: CheckedContinuation<MCPSocketHttpResponse, Error>) {
        headContinuation = continuation
        guard !finished else {
            resolveHead(.failure(CancellationError()))
            return
        }
        armIdleTimer()
        do {
            try connectSocket()
        } catch {
            fail(error)
        }
    }

    private func connectSocket() throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw connectFailure() }
        var transferred = false
        defer { if !transferred { close(descriptor) } }
        var noSigPipe: Int32 = 1
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw connectFailure()
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            socketPath.utf8CString.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 {
            transferred = true
            acceptConnected(descriptor)
            return
        }
        guard errno == EINPROGRESS else { throw connectFailure() }
        let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { @Sendable [self] in
            var code: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &code, &size) == 0, code == 0 else {
                fail(MCPSocketHttpError.connectFailed(String(cString: strerror(code == 0 ? errno : code))))
                return
            }
            connected = true
            connecting?.cancel()
            connecting = nil
        }
        source.setCancelHandler { @Sendable [self] in
            if connected && !finished {
                acceptConnected(descriptor)
            } else {
                close(descriptor)
            }
        }
        connecting = source
        transferred = true
        source.resume()
    }

    private func acceptConnected(_ descriptor: Int32) {
        do {
            try MCPHandshakeTrust.verifyConnectedPeer(descriptor: descriptor, expectedPID: expectedPID)
        } catch {
            close(descriptor)
            fail(MCPSocketHttpError.peerChanged)
            return
        }
        let stream = MCPUnixSocketConnection(descriptor: descriptor)
        connection = stream
        stream.start { _ in }
        // A server may answer and close before reading the request (a 503 at capacity).
        stream.send(request) { _ in }
        receiveNext()
    }

    private func connectFailure() -> MCPSocketHttpError {
        .connectFailed(String(cString: strerror(errno)))
    }

    private func receiveNext() {
        connection?.receive(maximumLength: Self.receiveChunkSize) { [self] content, isComplete, error in
            queue.async { self.received(content, isComplete: isComplete, error: error) }
        }
    }

    private func received(_ content: Data?, isComplete: Bool, error: String?) {
        guard !finished else { return }
        if let content, !content.isEmpty {
            armIdleTimer()
            do {
                consume(try reader.feed(content))
            } catch {
                fail(MCPSocketHttpError.malformedResponse(String(describing: error)))
                return
            }
        }
        guard !finished else { return }
        if let error {
            fail(MCPSocketHttpError.connectionClosed(error))
            return
        }
        if isComplete {
            do {
                consume(try reader.finish())
            } catch {
                fail(MCPSocketHttpError.connectionClosed(String(describing: error)))
            }
            return
        }
        receiveNext()
    }

    private func consume(_ events: [HttpResponseEvent]) {
        for event in events {
            switch event {
            case .head(let status, let headers):
                guard let stream = body else { continue }
                body = nil
                resolveHead(.success(MCPSocketHttpResponse(status: status, headers: headers, body: stream)))
            case .body(let data):
                bodyContinuation.yield(data)
            case .end:
                finished = true
                stopIdleTimer()
                bodyContinuation.finish()
                connection?.cancel()
                connection = nil
            }
        }
    }

    private func fail(_ error: Error) {
        guard !finished else { return }
        finished = true
        body = nil
        stopIdleTimer()
        resolveHead(.failure(error))
        bodyContinuation.finish(throwing: error)
        connecting?.cancel()
        connecting = nil
        connection?.cancel()
        connection = nil
    }

    private func resolveHead(_ result: Result<MCPSocketHttpResponse, Error>) {
        guard !headResolved, let continuation = headContinuation else { return }
        headResolved = true
        headContinuation = nil
        continuation.resume(with: result)
    }

    private func armIdleTimer() {
        let deadline = DispatchTime.now() + Self.seconds(idleTimeout)
        if let idleTimer {
            idleTimer.schedule(deadline: deadline)
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { @Sendable [weak self] in
            self?.fail(MCPSocketHttpError.timedOut)
        }
        timer.schedule(deadline: deadline)
        idleTimer = timer
        timer.resume()
    }

    private func stopIdleTimer() {
        idleTimer?.cancel()
        idleTimer = nil
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
