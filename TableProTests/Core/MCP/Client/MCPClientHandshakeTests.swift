//
//  MCPClientHandshakeTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

/// Records every request the transport makes and answers from a scripted queue, so the tests can
/// assert on the protocol rather than on a live server.
private final class StubMCPServerProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status: Int = 200
        var contentType: String = "application/json"
        var headers: [String: String] = [:]
        var body: Data = Data()
        /// Answers and then keeps the stream open, which is what a server that does not close its
        /// event stream after the response looks like. The specification only says a server SHOULD
        /// close it.
        var leavesStreamOpen: Bool = false
    }

    struct Recorded {
        let method: String
        let headers: [String: String]
        let body: Data

        var rpcMethod: String? {
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                return nil
            }
            return object["method"] as? String
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var queue: [Reply] = []
    nonisolated(unsafe) private static var recorded: [Recorded] = []

    static func reset(replies: [Reply]) {
        lock.lock(); defer { lock.unlock() }
        queue = replies
        recorded = []
    }

    static var requests: [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    private static func next(recording request: URLRequest) -> Reply {
        lock.lock(); defer { lock.unlock() }
        recorded.append(
            Recorded(
                method: request.httpMethod ?? "",
                headers: request.allHTTPHeaderFields ?? [:],
                body: Self.body(of: request)
            )
        )
        return queue.isEmpty ? Reply() : queue.removeFirst()
    }

    /// `URLSession` hands a `URLProtocol` the body as a stream rather than as `httpBody`, so a test
    /// that only read `httpBody` would assert against nothing.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let reply = Self.next(recording: request)
        var headers = reply.headers
        headers["Content-Type"] = reply.contentType
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers
              )
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        guard !reply.leavesStreamOpen else { return }
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("MCP client handshake", .serialized)
struct MCPClientHandshakeTests {
    private static func makeSession(
        replies: [StubMCPServerProtocol.Reply]
    ) -> MCPClientSession {
        StubMCPServerProtocol.reset(replies: replies)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubMCPServerProtocol.self]
        let endpoint = URL(string: "https://mcp.example.com/rpc")
        return MCPClientSession(
            configuration: MCPServerConfiguration(
                name: "Example",
                endpoint: endpoint ?? URL(fileURLWithPath: "/"),
                allowedConnectionIds: []
            ),
            transport: MCPRemoteServerTransport(
                endpoint: endpoint ?? URL(fileURLWithPath: "/"),
                bearerToken: "token",
                timeout: .seconds(5),
                urlSession: URLSession(configuration: configuration)
            )
        )
    }

    private static func rpcResult(id: Int, result: String) -> Data {
        Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8)
    }

    private static let emptyToolList = #"{"tools":[]}"#

    @Test("The client sends notifications/initialized before it lists tools")
    func sendsInitializedNotification() async throws {
        let session = Self.makeSession(replies: [
            .init(body: Self.rpcResult(id: 1, result: #"{"protocolVersion":"2026-07-28"}"#)),
            .init(status: 202),
            .init(body: Self.rpcResult(id: 2, result: Self.emptyToolList))
        ])

        _ = try await session.listTools()

        let methods = StubMCPServerProtocol.requests.compactMap(\.rpcMethod)
        #expect(methods == ["initialize", "notifications/initialized", "tools/list"])
    }

    @Test("A negotiated session id is sent on every request after initialize")
    func carriesNegotiatedSessionId() async throws {
        let session = Self.makeSession(replies: [
            .init(
                headers: ["Mcp-Session-Id": "session-abc"],
                body: Self.rpcResult(id: 1, result: #"{"protocolVersion":"2026-07-28"}"#)
            ),
            .init(status: 202),
            .init(body: Self.rpcResult(id: 2, result: Self.emptyToolList))
        ])

        _ = try await session.listTools()

        let requests = StubMCPServerProtocol.requests
        #expect(requests.count == 3)
        #expect(requests[0].headers["Mcp-Session-Id"] == nil)
        #expect(requests[1].headers["Mcp-Session-Id"] == "session-abc")
        #expect(requests[2].headers["Mcp-Session-Id"] == "session-abc")
    }

    @Test("A server that issues no session id is never sent one")
    func omitsSessionIdWhenServerIsStateless() async throws {
        let session = Self.makeSession(replies: [
            .init(body: Self.rpcResult(id: 1, result: #"{"protocolVersion":"2026-07-28"}"#)),
            .init(status: 202),
            .init(body: Self.rpcResult(id: 2, result: Self.emptyToolList))
        ])

        _ = try await session.listTools()

        #expect(StubMCPServerProtocol.requests.allSatisfy { $0.headers["Mcp-Session-Id"] == nil })
    }

    @Test("A failed initialize is retried rather than leaving the session marked handshaken")
    func failedHandshakeIsRetried() async throws {
        let session = Self.makeSession(replies: [
            .init(status: 500),
            .init(body: Self.rpcResult(id: 2, result: #"{"protocolVersion":"2026-07-28"}"#)),
            .init(status: 202),
            .init(body: Self.rpcResult(id: 3, result: Self.emptyToolList))
        ])

        await #expect(throws: MCPClientError.self) { _ = try await session.listTools() }

        /// The second attempt has to initialize again. Marking the handshake done before the round
        /// trip left every later call running against a server that never handshook.
        _ = try await session.listTools()

        let methods = StubMCPServerProtocol.requests.compactMap(\.rpcMethod)
        #expect(methods == ["initialize", "initialize", "notifications/initialized", "tools/list"])
    }

    @Test("An expired session is re-initialized once and the call is retried")
    func expiredSessionIsRecovered() async throws {
        let session = Self.makeSession(replies: [
            .init(
                headers: ["Mcp-Session-Id": "first"],
                body: Self.rpcResult(id: 1, result: #"{"protocolVersion":"2026-07-28"}"#)
            ),
            .init(status: 202),
            .init(status: 404),
            .init(
                headers: ["Mcp-Session-Id": "second"],
                body: Self.rpcResult(id: 3, result: #"{"protocolVersion":"2026-07-28"}"#)
            ),
            .init(status: 202),
            .init(body: Self.rpcResult(id: 4, result: Self.emptyToolList))
        ])

        _ = try await session.listTools()

        let requests = StubMCPServerProtocol.requests
        #expect(requests.compactMap(\.rpcMethod) == [
            "initialize", "notifications/initialized", "tools/list",
            "initialize", "notifications/initialized", "tools/list"
        ])
        #expect(requests.last?.headers["Mcp-Session-Id"] == "second")
    }

    @Test("A response delivered as an event stream is read past the notifications ahead of it")
    func readsResponseFromEventStream() async throws {
        let progress = #"{"jsonrpc":"2.0","method":"notifications/progress","params":{}}"#
        let answer = #"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"search","description":"d"}]}}"#
        let stream = "data: \(progress)\n\ndata: \(answer)\n\n"

        let session = Self.makeSession(replies: [
            .init(body: Self.rpcResult(id: 1, result: #"{"protocolVersion":"2026-07-28"}"#)),
            .init(status: 202),
            .init(contentType: "text/event-stream", body: Data(stream.utf8))
        ])

        let tools = try await session.listTools()

        #expect(tools.map(\.name) == ["search"])
    }

    /// The specification says a server SHOULD close the event stream once the response is sent, and
    /// several do not. Buffering the whole body first meant every call against one of those sat
    /// until the timeout and then failed, having already been answered.
    @Test("A response arrives even when the server never closes its event stream")
    func doesNotWaitForAStreamTheServerKeepsOpen() async throws {
        let answer = #"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"search","description":"d"}]}}"#
        let session = Self.makeSession(replies: [
            .init(body: Self.rpcResult(id: 1, result: #"{"protocolVersion":"2026-07-28"}"#)),
            .init(status: 202),
            .init(
                contentType: "text/event-stream",
                body: Data("data: \(answer)\n\n".utf8),
                leavesStreamOpen: true
            )
        ])

        let tools = try await session.listTools()

        #expect(tools.map(\.name) == ["search"])
    }

    /// `tools/list` is paginated. A client that stops at the first page silently offers the model a
    /// subset of what the server has, and nothing anywhere says so.
    @Test("Every page of a paginated tool list is read")
    func followsToolListPagination() async throws {
        let firstPage = #"{"tools":[{"name":"one","description":"d"}],"nextCursor":"page-2"}"#
        let secondPage = #"{"tools":[{"name":"two","description":"d"}]}"#
        let session = Self.makeSession(replies: [
            .init(body: Self.rpcResult(id: 1, result: #"{"protocolVersion":"2026-07-28"}"#)),
            .init(status: 202),
            .init(body: Self.rpcResult(id: 2, result: firstPage)),
            .init(body: Self.rpcResult(id: 3, result: secondPage))
        ])

        let tools = try await session.listTools()

        #expect(tools.map(\.name) == ["one", "two"])
        let cursors = StubMCPServerProtocol.requests.compactMap { request -> String? in
            guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let params = object["params"] as? [String: Any]
            else { return nil }
            return params["cursor"] as? String
        }
        #expect(cursors == ["page-2"])
    }

    /// The specification has the client send the negotiated version on every later request. A server
    /// that answered with an older one is being told TablePro ignored it otherwise.
    @Test("The version the server chose is what later requests carry")
    func carriesTheNegotiatedProtocolVersion() async throws {
        let older = MCPProtocolVersion.v20250618.rawValue
        let session = Self.makeSession(replies: [
            .init(body: Self.rpcResult(id: 1, result: #"{"protocolVersion":"\#(older)"}"#)),
            .init(status: 202),
            .init(body: Self.rpcResult(id: 2, result: Self.emptyToolList))
        ])

        _ = try await session.listTools()

        let versions = StubMCPServerProtocol.requests.map { $0.headers["MCP-Protocol-Version"] }
        #expect(versions.first == MCPProtocolVersion.latest.rawValue)
        #expect(versions.dropFirst().allSatisfy { $0 == older })
    }

    @Test("A version TablePro does not implement is not echoed back")
    func ignoresAnUnsupportedNegotiatedVersion() async throws {
        let session = Self.makeSession(replies: [
            .init(body: Self.rpcResult(id: 1, result: #"{"protocolVersion":"1999-01-01"}"#)),
            .init(status: 202),
            .init(body: Self.rpcResult(id: 2, result: Self.emptyToolList))
        ])

        _ = try await session.listTools()

        #expect(
            StubMCPServerProtocol.requests
                .allSatisfy { $0.headers["MCP-Protocol-Version"] == MCPProtocolVersion.latest.rawValue }
        )
    }

    @Test("TablePro's own bridge headers are never sent to an outside server")
    func sendsNoBridgeHeaders() async throws {
        let session = Self.makeSession(replies: [
            .init(body: Self.rpcResult(id: 1, result: #"{"protocolVersion":"2026-07-28"}"#)),
            .init(status: 202),
            .init(body: Self.rpcResult(id: 2, result: Self.emptyToolList))
        ])

        _ = try await session.listTools()

        for request in StubMCPServerProtocol.requests {
            #expect(request.headers["Mcp-Method"] == nil)
            #expect(request.headers["Mcp-Name"] == nil)
            #expect(request.headers["Authorization"] == "Bearer token")
            #expect(request.headers["MCP-Protocol-Version"] == MCPProtocolVersion.latest.rawValue)
        }
    }

    @Test("An unreachable outside server is not reported as TablePro's own server being down")
    func reportsTheOutsideServerRatherThanTablePro() async throws {
        let session = Self.makeSession(replies: [.init(status: 503)])

        await #expect(throws: MCPClientError.self) { _ = try await session.listTools() }

        do {
            _ = try await Self.makeSession(replies: [.init(status: 503)]).listTools()
        } catch let error as MCPClientError {
            #expect(!error.localizedMessage.contains("TablePro"))
        }
    }
}
