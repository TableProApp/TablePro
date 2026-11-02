import Foundation
import Network

public struct LoopbackRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public struct LoopbackResponse: Sendable {
    public let status: Int
    public var headers: [String: String]
    public var body: String

    public init(status: Int, headers: [String: String] = [:], body: String = "") {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

// Answers each request on 127.0.0.1 with the handler's reply and keeps what it was sent.
public final class LoopbackHTTPResponder: @unchecked Sendable {
    private let listener: NWListener
    private let handler: @Sendable (LoopbackRequest) -> LoopbackResponse
    private let lock = NSLock()
    private var received: [LoopbackRequest] = []

    public init(handler: @escaping @Sendable (LoopbackRequest) -> LoopbackResponse) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        self.handler = handler
    }

    public var requests: [LoopbackRequest] {
        lock.withLock { received }
    }

    public var port: Int {
        Int(listener.port?.rawValue ?? 0)
    }

    public func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)") ?? URL(fileURLWithPath: "/")
    }

    public func start() async throws {
        let started = StartOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if started.claim() { continuation.resume() }
                case .failed(let error):
                    if started.claim() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    public func stop() {
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            if let request = Self.parse(accumulated) {
                lock.withLock { received.append(request) }
                connection.send(content: Self.serialize(handler(request)), completion: .contentProcessed { _ in
                    connection.cancel()
                })
                return
            }
            if isComplete {
                connection.cancel()
                return
            }
            read(connection, buffer: accumulated)
        }
    }

    private static func parse(_ data: Data) -> LoopbackRequest? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<end.lowerBound], encoding: .utf8)
        else {
            return nil
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = headers.first { $0.key.caseInsensitiveCompare("Content-Length") == .orderedSame }
            .flatMap { Int($0.value) } ?? 0
        guard data.count - end.upperBound >= length else { return nil }
        return LoopbackRequest(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers)
    }

    private static func serialize(_ response: LoopbackResponse) -> Data {
        var text = "HTTP/1.1 \(response.status) Status\r\n"
        for (name, value) in response.headers {
            text += "\(name): \(value)\r\n"
        }
        text += "Content-Length: \(response.body.utf8.count)\r\nConnection: close\r\n\r\n\(response.body)"
        return Data(text.utf8)
    }
}

private final class StartOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}
