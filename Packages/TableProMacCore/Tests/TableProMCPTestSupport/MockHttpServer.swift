import Foundation
import Network

public struct MockHttpRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [(String, String)]
    public let body: Data

    public func header(_ name: String) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }
}

public struct MockHttpResponse: Sendable {
    public let status: Int
    public let headers: [(String, String)]
    public let body: Data

    public init(status: Int, headers: [(String, String)], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

private actor MockServerState {
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

public final class MockHttpServer: @unchecked Sendable {
    private var listener: NWListener?
    private let state = MockServerState()
    private let lock = NSLock()
    private var assignedPort: UInt16 = 0
    private var connections: [NWConnection] = []

    public init() {}

    public var port: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return assignedPort
    }

    public var requests: [MockHttpRequest] {
        get async { await state.requests }
    }

    public func setResponse(_ response: MockHttpResponse) async {
        await state.setResponses([response])
    }

    public func setResponses(_ responses: [MockHttpResponse]) async {
        await state.setResponses(responses)
    }

    public func respondWithJson(_ body: Data) async {
        await setResponse(MockHttpResponse(
            status: 200,
            headers: [("Content-Type", "application/json")],
            body: body
        ))
    }

    public func start() async throws {
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

    public func stop() async {
        let (listener, connections) = lock.withLock { () -> (NWListener?, [NWConnection]) in
            let taken = (self.listener, self.connections)
            self.listener = nil
            self.connections = []
            return taken
        }
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
            maximumLength: 64 * 1_024
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
