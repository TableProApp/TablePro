import Foundation
@testable import TableProTrinoCore
import Testing

/// Plays a Trino coordinator: a statement POST answers at once, `SELECT hang` hands back a nextUri
/// whose GET never answers until cancelled, and every DELETE is recorded, so a test can hold
/// several statements in flight and watch what a cancel does to each.
private final class TrinoStubProtocol: URLProtocol, @unchecked Sendable {
    static let origin = "https://h:8443"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var startedRequests: [String] = []
    nonisolated(unsafe) private static var queryCount = 0
    nonisolated(unsafe) private static var timeout: TimeInterval?

    static func reset() {
        lock.withLock {
            startedRequests = []
            queryCount = 0
            timeout = nil
        }
    }

    static var started: [String] {
        lock.withLock { startedRequests }
    }

    static var lastTimeout: TimeInterval? {
        lock.withLock { timeout }
    }

    static var parkedPolls: [String] {
        started.filter { $0.hasPrefix("GET /v1/statement/executing/") }.map { String($0.dropFirst("GET ".count)) }
    }

    static var deletes: [String] {
        started.filter { $0.hasPrefix("DELETE ") }.map { String($0.dropFirst("DELETE ".count)) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        Self.lock.withLock {
            Self.startedRequests.append("\(method) \(path)")
            Self.timeout = request.timeoutInterval
        }

        switch (method, path) {
        case ("POST", "/v1/statement"):
            respond(body: statementReply(sql: Self.bodyText(of: request)))
        case ("DELETE", "/slow"):
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { self.respond(status: 204, body: "") }
        case ("DELETE", _):
            respond(status: 204, body: "")
        case (_, "/ok"):
            respond(body: #"{"id":"ok"}"#, headers: ["X-Trino-Set-Schema": "analytics"])
        default:
            return
        }
    }

    override func stopLoading() {}

    private func statementReply(sql: String) -> String {
        let queryId = Self.lock.withLock { () -> String in
            Self.queryCount += 1
            return "q\(Self.queryCount)"
        }
        guard sql == "SELECT hang" else {
            let column = #"{"name":"n","type":"bigint","typeSignature":{"rawType":"bigint"}}"#
            return #"{"id":"\#(queryId)","columns":[\#(column)],"data":[[1]]}"#
        }
        return #"{"id":"\#(queryId)","nextUri":"\#(Self.origin)/v1/statement/executing/\#(queryId)/1"}"#
    }

    private func respond(status: Int = 200, body: String, headers: [String: String] = [:]) {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func bodyText(of request: URLRequest) -> String {
        if let body = request.httpBody {
            return String(bytes: body, encoding: .utf8) ?? ""
        }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return String(bytes: data, encoding: .utf8) ?? ""
    }
}

@Suite("Trino URLSession transport", .serialized)
struct TrinoURLSessionTransportTests {
    init() {
        TrinoStubProtocol.reset()
    }

    private func transport() -> URLSessionTrinoTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TrinoStubProtocol.self]
        return URLSessionTrinoTransport(tls: .systemDefault, configuration: configuration)
    }

    private func client(_ transport: URLSessionTrinoTransport) -> TrinoStatementClient {
        TrinoStatementClient(
            transport: transport,
            config: TrinoClientConfig(host: "h", port: 8_443, useTLS: true, user: "u"),
            session: TrinoSessionState(catalog: "c", schema: "s")
        )
    }

    private func request(_ method: TrinoHTTPRequest.Method, _ path: String, timeout: Int = 60) throws -> TrinoHTTPRequest {
        TrinoHTTPRequest(
            method: method,
            url: try #require(URL(string: TrinoStubProtocol.origin + path)),
            headers: [:],
            timeoutSeconds: timeout
        )
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0 ..< 300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("A request carries its own timeout and returns the status, headers and body")
    func roundTrip() async throws {
        let response = try await transport().send(try request(.get, "/ok", timeout: 330))

        #expect(response.statusCode == 200)
        #expect(response.headers.first("x-trino-set-schema") == "analytics")
        #expect(String(bytes: response.body, encoding: .utf8) == #"{"id":"ok"}"#)
        #expect(TrinoStubProtocol.lastTimeout == 330)
    }

    @Test("Cancelling everything stops every request in flight, not just the latest")
    func cancelAllStopsEveryRequest() async throws {
        let transport = transport()
        let firstRequest = try request(.get, "/hang/1")
        let secondRequest = try request(.get, "/hang/2")
        let first = Task { try await transport.send(firstRequest) }
        let second = Task { try await transport.send(secondRequest) }
        await waitUntil { transport.inFlightCount == 2 }

        transport.cancelAll()

        for task in [first, second] {
            await #expect(throws: TrinoError.cancelled) { try await task.value }
        }
        #expect(transport.inFlightCount == 0)
    }

    @Test("Cancelling the awaiting task cancels its request")
    func taskCancellation() async throws {
        let transport = transport()
        let hanging = try request(.get, "/hang")
        let task = Task { try await transport.send(hanging) }
        await waitUntil { transport.inFlightCount == 1 }

        task.cancel()

        await #expect(throws: TrinoError.cancelled) { try await task.value }
        #expect(transport.inFlightCount == 0)
    }

    @Test("Cancelling everything leaves a DELETE to finish telling Trino to stop")
    func cancelAllSparesDelete() async throws {
        let transport = transport()
        let deleteRequest = try request(.delete, "/slow")
        let pollRequest = try request(.get, "/hang")
        let delete = Task { try await transport.send(deleteRequest) }
        let poll = Task { try await transport.send(pollRequest) }
        await waitUntil { transport.inFlightCount == 1 && TrinoStubProtocol.started.contains("DELETE /slow") }

        transport.cancelAll()

        await #expect(throws: TrinoError.cancelled) { try await poll.value }
        #expect(try await delete.value.statusCode == 204)
    }

    @Test("Cancel stops every running statement and deletes each on the server")
    func cancelStopsEveryStatement() async throws {
        let transport = transport()
        let client = client(transport)
        let first = Task { try await client.execute("SELECT hang") }
        let second = Task { try await client.execute("SELECT hang") }
        await waitUntil { TrinoStubProtocol.parkedPolls.count == 2 }
        let parked = TrinoStubProtocol.parkedPolls

        let finished = try await client.execute("SELECT 1")
        client.cancel()

        #expect(finished.rows == [[.text("1")]])
        for task in [first, second] {
            await #expect(throws: TrinoError.cancelled) { try await task.value }
        }
        await waitUntil { TrinoStubProtocol.deletes.count == 2 }
        #expect(Set(TrinoStubProtocol.deletes) == Set(parked))
    }

    @Test("Cancelling the task running a statement cancels its poll and deletes it on the server")
    func taskCancellationReleasesStatement() async throws {
        let client = client(transport())
        let task = Task { try await client.execute("SELECT hang") }
        await waitUntil { TrinoStubProtocol.parkedPolls.count == 1 }
        let parked = TrinoStubProtocol.parkedPolls

        task.cancel()

        await #expect(throws: TrinoError.cancelled) { try await task.value }
        await waitUntil { TrinoStubProtocol.deletes.count == 1 }
        #expect(TrinoStubProtocol.deletes == parked)
    }
}
