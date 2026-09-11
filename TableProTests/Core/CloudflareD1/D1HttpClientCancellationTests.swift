import Foundation
import TableProPluginKit
import Testing

/// Plays the D1 REST API: a statement whose SQL is `SELECT hang` never answers until cancelled,
/// any other statement answers at once, so a test can hold several requests in flight and watch
/// what a cancel does to each.
private final class D1StubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastRequest: URLRequest?

    static var recorded: URLRequest? {
        lock.withLock { lastRequest }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.lastRequest = request }
        guard !Self.bodyText(of: request).contains("SELECT hang"),
              let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else { return }
        let body = #"{"result":[{"results":{"columns":["n"],"rows":[[1]]},"success":true}],"success":true}"#
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyText(of request: URLRequest) -> String {
        guard let stream = request.httpBodyStream else {
            return String(bytes: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        }
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

@Suite("Cloudflare D1 HTTP client cancellation", .serialized)
struct D1HttpClientCancellationTests {
    private func connectedClient() -> D1HttpClient {
        let client = D1HttpClient(accountId: "account", apiToken: "token", databaseId: "database")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [D1StubProtocol.self]
        client.createSession(configuration: configuration)
        return client
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0 ..< 300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("A statement carries the token and the query timeout and returns its rows")
    func roundTrip() async throws {
        let client = connectedClient()
        client.setQueryTimeout(300)

        let payload = try await client.executeRaw(sql: "SELECT 1")

        #expect(payload.results.columns == ["n"])
        #expect(payload.results.rows?.first?.first?.stringValue == "1")
        let request = try #require(D1StubProtocol.recorded)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        #expect(request.timeoutInterval == HttpQueryTimeout(serverTimeoutSeconds: 300).requestTimeoutInterval)
        #expect(client.inFlightCount == 0)
    }

    @Test("Cancelling everything stops every request in flight, not just the latest")
    func cancelAllStopsEveryRequest() async throws {
        let client = connectedClient()
        let query = Task { try await client.executeRaw(sql: "SELECT hang") }
        let sidebarRead = Task { try await client.executeRaw(sql: "SELECT hang") }
        await waitUntil { client.inFlightCount == 2 }

        client.cancelAll()

        await #expect(throws: CancellationError.self) { try await query.value }
        await #expect(throws: CancellationError.self) { try await sidebarRead.value }
        #expect(client.inFlightCount == 0)
    }

    @Test("A request that finishes leaves the others cancellable")
    func finishedRequestKeepsOthersTracked() async throws {
        let client = connectedClient()
        let query = Task { try await client.executeRaw(sql: "SELECT hang") }
        await waitUntil { client.inFlightCount == 1 }

        _ = try await client.executeRaw(sql: "SELECT 1")
        client.cancelAll()

        await #expect(throws: CancellationError.self) { try await query.value }
    }

    @Test("Cancelling the awaiting task cancels its request")
    func taskCancellation() async throws {
        let client = connectedClient()
        let query = Task { try await client.executeRaw(sql: "SELECT hang") }
        await waitUntil { client.inFlightCount == 1 }

        query.cancel()

        await #expect(throws: CancellationError.self) { try await query.value }
        #expect(client.inFlightCount == 0)
    }

    @Test("Disconnecting cancels every request in flight")
    func invalidateSessionCancels() async throws {
        let client = connectedClient()
        let query = Task { try await client.executeRaw(sql: "SELECT hang") }
        await waitUntil { client.inFlightCount == 1 }

        client.invalidateSession()

        await #expect(throws: CancellationError.self) { try await query.value }
    }
}
