import Foundation
import Network

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
        idleTimeout: Duration
    ) async throws -> MCPSocketHttpResponse {
        guard socketPath.hasPrefix("/"), MCPSocketLocation.fits(socketPath) else {
            throw MCPSocketHttpError.invalidSocketPath(socketPath)
        }
        let exchange = MCPUnixSocketHttpExchange(
            socketPath: socketPath,
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

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.TablePro.MCP.UnixSocketHttpClient")
    private let request: Data
    private let idleTimeout: Duration
    private let bodyContinuation: AsyncThrowingStream<Data, Error>.Continuation
    // Handed to the response, so a response nobody reads ends the stream and closes the connection.
    private var body: AsyncThrowingStream<Data, Error>?

    private var reader = HttpResponseReader()
    private var headContinuation: CheckedContinuation<MCPSocketHttpResponse, Error>?
    private var headResolved = false
    private var isReady = false
    private var finished = false
    private var idleTimer: DispatchSourceTimer?

    init(socketPath: String, request: Data, idleTimeout: Duration) {
        connection = NWConnection(
            to: .unix(path: socketPath),
            using: NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        )
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
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                handleReady()
            case .waiting(let error), .failed(let error):
                // After connect, the peer's close fails the state before its last bytes are read.
                guard !isReady else { return }
                fail(MCPSocketHttpError.connectFailed(error.localizedDescription))
            case .cancelled:
                connection.stateUpdateHandler = nil
                fail(MCPSocketHttpError.connectionClosed("cancelled"))
            default:
                break
            }
        }
        armIdleTimer()
        connection.start(queue: queue)
    }

    private func handleReady() {
        guard !isReady, !finished else { return }
        isReady = true
        // A server may answer and close before reading the request (a 503 at capacity).
        connection.send(content: request, completion: .contentProcessed { _ in })
        receiveNext()
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.receiveChunkSize) { [self] content, _, isComplete, error in
            guard !finished else { return }
            if let content, !content.isEmpty {
                armIdleTimer()
                do {
                    try consume(reader.feed(content))
                } catch {
                    fail(MCPSocketHttpError.malformedResponse(String(describing: error)))
                    return
                }
            }
            guard !finished else { return }
            if let error {
                fail(MCPSocketHttpError.connectionClosed(error.localizedDescription))
                return
            }
            if isComplete {
                do {
                    try consume(reader.finish())
                } catch {
                    fail(MCPSocketHttpError.connectionClosed(String(describing: error)))
                }
                return
            }
            receiveNext()
        }
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
                connection.cancel()
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
        connection.cancel()
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
