import Darwin
import Foundation
import TableProMCP

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
    public enum Framing: Sendable, Equatable {
        case contentLength
        case chunked(size: Int)
        case untilClose
    }

    public let status: Int
    public let headers: [(String, String)]
    public let body: Data
    public let framing: Framing

    public init(status: Int, headers: [(String, String)], body: Data, framing: Framing = .contentLength) {
        self.status = status
        self.headers = headers
        self.body = body
        self.framing = framing
    }
}

// Short, since sun_path holds 104 bytes, and 0700, since the bridge trusts no other socket folder.
public enum MCPTestSocketFolder {
    public static func url() -> URL {
        let name = "mcp-" + UUID().uuidString.prefix(8).lowercased()
        return MCPSocketLocation.userTemporaryDirectory().appendingPathComponent(name, isDirectory: true)
    }

    public static func make() throws -> URL {
        let folder = url()
        try create(folder)
        return folder
    }

    public static func create(_ folder: URL) throws {
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }
}

private actor MockServerState {
    private(set) var requests: [MockHttpRequest] = []
    private var responses: [MockHttpResponse] = []
    private var handler: (@Sendable (MockHttpRequest) -> MockHttpResponse?)?

    func setResponses(_ responses: [MockHttpResponse]) {
        self.responses = responses
    }

    func setHandler(_ handler: @escaping @Sendable (MockHttpRequest) -> MockHttpResponse?) {
        self.handler = handler
    }

    func record(_ request: MockHttpRequest) -> MockHttpResponse {
        requests.append(request)
        if let handler, let answer = handler(request) {
            return answer
        }
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
    public let socketPath: String

    private let ownedFolder: URL?
    private let state = MockServerState()
    private let lock = NSLock()
    private var listener: MCPUnixSocketListener?
    private var connections: [MCPUnixSocketConnection] = []

    public init(socketPath: String? = nil) {
        if let socketPath {
            self.socketPath = socketPath
            ownedFolder = nil
        } else {
            let folder = MCPTestSocketFolder.url()
            self.socketPath = MCPSocketLocation.primarySocket(in: folder).path
            ownedFolder = folder
        }
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

    // Answers first; a nil answer falls back to the queued responses.
    public func setHandler(_ handler: @escaping @Sendable (MockHttpRequest) -> MockHttpResponse?) async {
        await state.setHandler(handler)
    }

    public func respondWithJson(_ body: Data) async {
        await setResponse(MockHttpResponse(
            status: 200,
            headers: [("Content-Type", "application/json")],
            body: body
        ))
    }

    public func start() async throws {
        if let ownedFolder {
            try MCPTestSocketFolder.create(ownedFolder)
        }
        let listener = MCPUnixSocketListener(path: socketPath) { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.serve(connection)
        }
        try listener.start()
        lock.withLock { self.listener = listener }
    }

    public func stop() async {
        let (listener, connections) = lock.withLock { () -> (MCPUnixSocketListener?, [MCPUnixSocketConnection]) in
            let taken = (self.listener, self.connections)
            self.listener = nil
            self.connections = []
            return taken
        }
        listener?.stop()
        for connection in connections {
            connection.cancel()
        }
        if let ownedFolder {
            try? FileManager.default.removeItem(at: ownedFolder)
        }
    }

    private func serve(_ connection: MCPUnixSocketConnection) {
        lock.withLock { connections.append(connection) }
        connection.start { [weak self] streamState in
            guard case .ready = streamState else { return }
            self?.read(connection, parser: HttpRequestStreamParser())
        }
    }

    private func read(_ connection: MCPUnixSocketConnection, parser: HttpRequestStreamParser) {
        connection.receive(maximumLength: 65_536) { [weak self] data, isComplete, failure in
            guard let self else {
                connection.cancel()
                return
            }
            var parser = parser
            if let data {
                parser.append(data)
            }
            let parsed: HttpParsedRequest?
            do {
                parsed = try parser.next()
            } catch {
                connection.cancel()
                return
            }
            if let parsed {
                let request = MockHttpRequest(
                    method: parsed.head.method.rawValue,
                    path: parsed.head.path,
                    headers: parsed.head.headers.all,
                    body: parsed.body
                )
                let state = self.state
                Task {
                    let response = await state.record(request)
                    Self.send(Self.serialize(response)[...], on: connection)
                }
                return
            }
            if isComplete || failure != nil {
                connection.cancel()
                return
            }
            self.read(connection, parser: parser)
        }
    }

    private static func send(_ pieces: ArraySlice<Data>, on connection: MCPUnixSocketConnection) {
        guard let first = pieces.first else {
            connection.cancel()
            return
        }
        connection.send(first) { failure in
            guard failure == nil else {
                connection.cancel()
                return
            }
            send(pieces.dropFirst(), on: connection)
        }
    }

    private static func serialize(_ response: MockHttpResponse) -> [Data] {
        var headers = response.headers
        switch response.framing {
        case .contentLength:
            if !headers.contains(where: { $0.0.lowercased() == "content-length" }) {
                headers.append(("Content-Length", "\(response.body.count)"))
            }
        case .chunked:
            headers.append(("Transfer-Encoding", "chunked"))
        case .untilClose:
            break
        }
        if !headers.contains(where: { $0.0.lowercased() == "connection" }) {
            headers.append(("Connection", "close"))
        }

        var head = "HTTP/1.1 \(response.status) \(reasonPhrase(for: response.status))\r\n"
        for (key, value) in headers {
            head.append("\(key): \(value)\r\n")
        }
        head.append("\r\n")

        guard case .chunked(let size) = response.framing else {
            var data = Data(head.utf8)
            data.append(response.body)
            return [data]
        }
        var pieces = [Data(head.utf8)]
        var offset = 0
        while offset < response.body.count {
            let end = min(offset + max(1, size), response.body.count)
            var piece = Data(String(end - offset, radix: 16).utf8)
            piece.append(Data("\r\n".utf8))
            piece.append(response.body.subdata(in: offset..<end))
            piece.append(Data("\r\n".utf8))
            pieces.append(piece)
            offset = end
        }
        pieces.append(Data("0\r\n\r\n".utf8))
        return pieces
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
