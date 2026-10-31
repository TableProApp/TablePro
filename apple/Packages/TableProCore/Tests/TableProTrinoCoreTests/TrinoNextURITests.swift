import Foundation
import TableProTrinoCore
import Testing

private final class PagingTransport: TrinoTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TrinoHTTPRequest] = []
    private let nextUri: String

    init(nextUri: String) {
        self.nextUri = nextUri
    }

    var requests: [TrinoHTTPRequest] {
        lock.withLock { recorded }
    }

    func send(_ request: TrinoHTTPRequest) async throws -> TrinoHTTPResponse {
        lock.withLock { recorded.append(request) }
        let body = request.method == .post ? #"{"id":"q1","nextUri":"\#(nextUri)"}"# : #"{"id":"q1"}"#
        return TrinoHTTPResponse(statusCode: 200, headers: TrinoHeaderFields([:]), body: Data(body.utf8))
    }

    func cancelAll() {}
}

struct TrinoNextURITests {
    private func client(_ transport: PagingTransport, port: Int = 8_443, useTLS: Bool = true) -> TrinoStatementClient {
        let config = TrinoClientConfig(
            host: "trino.example",
            port: port,
            useTLS: useTLS,
            user: "analyst",
            auth: useTLS ? .basic(password: "secret") : .none
        )
        return TrinoStatementClient(transport: transport, config: config, session: TrinoSessionState())
    }

    @Test("A nextUri on the coordinator is followed with the credential")
    func nextUriOnTheCoordinatorIsFollowed() async throws {
        let transport = PagingTransport(nextUri: "https://TRINO.example:8443/v1/statement/executing/q1/1")
        _ = try await client(transport).execute("SELECT 1")
        #expect(transport.requests.map(\.method) == [.post, .get])
        #expect(transport.requests.last?.headers["Authorization"] != nil)
    }

    @Test("A nextUri that leaves out the default port is still the coordinator")
    func nextUriWithoutTheDefaultPortIsFollowed() async throws {
        let transport = PagingTransport(nextUri: "https://trino.example/v1/statement/executing/q1/1")
        _ = try await client(transport, port: 443).execute("SELECT 1")
        #expect(transport.requests.map(\.method) == [.post, .get])
    }

    @Test("A nextUri on another host or port gets no request", arguments: [
        "https://other.example:8443/v1/statement/executing/q1/1",
        "https://trino.example:9443/v1/statement/executing/q1/1",
        "https://trino.example/v1/statement/executing/q1/1",
        "https://trino.example.other.example:8443/v1/statement/executing/q1/1",
        "https://trino.example:8443@other.example/v1/statement/executing/q1/1",
        "/v1/statement/executing/q1/1"
    ])
    func nextUriElsewhereIsNotFollowed(nextUri: String) async {
        let transport = PagingTransport(nextUri: nextUri)
        await #expect(throws: TrinoError.self) {
            _ = try await client(transport).execute("SELECT 1")
        }
        #expect(transport.requests.map(\.method) == [.post])
    }

    @Test("A connection without TLS stays on its server too", arguments: [
        "http://other.example:8080/v1/statement/executing/q1/1",
        "https://trino.example:8080/v1/statement/executing/q1/1"
    ])
    func plainNextUriElsewhereIsNotFollowed(nextUri: String) async {
        let transport = PagingTransport(nextUri: nextUri)
        await #expect(throws: TrinoError.self) {
            _ = try await client(transport, port: 8_080, useTLS: false).execute("SELECT 1")
        }
        #expect(transport.requests.map(\.method) == [.post])
    }

    @Test("A plain http:// nextUri on a TLS connection keeps the message naming the proxy setting")
    func plainNextUriOnTLSNamesTheProxySetting() async {
        let transport = PagingTransport(nextUri: "http://trino.example:8443/v1/statement/executing/q1/1")
        await #expect {
            _ = try await client(transport).execute("SELECT 1")
        } throws: { error in
            error.localizedDescription.contains("plain http:// address")
        }
        #expect(transport.requests.map(\.method) == [.post])
    }
}
