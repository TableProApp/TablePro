import Foundation
import TableProTrinoCore
import Testing

// A coordinator that abandons the query once `clientTimeout` passes without a request, on a clock the test moves.
private final class IdleCoordinator: TrinoTransport, @unchecked Sendable {
    static let base = "https://trino.example:8443/v1/statement/executing/q1/s"
    static let clientTimeout: Duration = .seconds(300)

    private let lock = NSLock()
    private let headStatus: Int
    private var now: Duration = .zero
    private var lastContact: Duration = .zero
    private var abandoned = false
    private var recorded: [TrinoHTTPRequest] = []
    let deletes = AsyncStream<Void>.makeStream()

    init(headStatus: Int) {
        self.headStatus = headStatus
    }

    var requests: [TrinoHTTPRequest] {
        lock.withLock { recorded }
    }

    func advance(by interval: Duration) {
        lock.withLock { now += interval }
    }

    func send(_ request: TrinoHTTPRequest) async throws -> TrinoHTTPResponse {
        let (status, body) = lock.withLock { () -> (Int, String) in
            recorded.append(request)
            if now - lastContact > Self.clientTimeout { abandoned = true }
            lastContact = now
            if abandoned {
                return (200, #"{"id":"q1","error":{"message":"Query was abandoned","errorName":"ABANDONED_QUERY"}}"#)
            }
            switch request.method {
            case .post:
                return (200, #"{"id":"q1","nextUri":"\#(Self.base)/1"}"#)
            case .head:
                return (headStatus, "")
            case .delete:
                deletes.continuation.yield()
                return (204, "")
            case .get:
                return (200, Self.page(Int(request.url.lastPathComponent) ?? 0))
            }
        }
        return TrinoHTTPResponse(statusCode: status, headers: TrinoHeaderFields([:]), body: Data(body.utf8))
    }

    func cancelAll() {}

    private static func page(_ token: Int) -> String {
        let columns = #"[{"name":"n","type":"integer"}]"#
        let next = token < 3 ? #","nextUri":"\#(base)/\#(token + 1)""# : ""
        return #"{"id":"q1","columns":\#(columns),"data":[[\#(token)]]\#(next)}"#
    }
}

struct TrinoHeartbeatTests {
    private func client(_ transport: IdleCoordinator) -> TrinoStatementClient {
        let config = TrinoClientConfig(
            host: "trino.example",
            port: 8_443,
            useTLS: true,
            user: "analyst",
            auth: .basic(password: "secret")
        )
        return TrinoStatementClient(transport: transport, config: config, session: TrinoSessionState())
    }

    // Holds the first page for 20 minutes, sending a heartbeat every 30 seconds as a paced reader does.
    private func read(
        _ transport: IdleCoordinator,
        heartbeat: TrinoHeartbeat,
        sendsHeartbeats: Bool = true
    ) async throws -> (rows: [String], requestsWhileHeld: [TrinoHTTPRequest]) {
        var rows: [String] = []
        var requestsWhileHeld: [TrinoHTTPRequest] = []
        try await client(transport).executeStreamed(
            "SELECT n FROM t",
            heartbeat: heartbeat,
            onColumns: { _ in },
            onPage: { page, keepAlive in
                rows += page.compactMap { row -> String? in
                    guard case .text(let text)? = row.first else { return nil }
                    return text
                }
                guard rows.count == 1 else { return }
                let before = transport.requests.count
                for _ in 0..<40 {
                    transport.advance(by: .seconds(30))
                    if sendsHeartbeats { try await keepAlive() }
                }
                requestsWhileHeld = Array(transport.requests.dropFirst(before))
            }
        )
        return (rows, requestsWhileHeld)
    }

    @Test("A held page outlives the client timeout on HEAD heartbeats, and no later page is fetched while held")
    func headHeartbeatsKeepTheQuery() async throws {
        let transport = IdleCoordinator(headStatus: 200)
        let (rows, held) = try await read(transport, heartbeat: .head)
        #expect(rows == ["1", "2", "3"])
        #expect(held.count == 40)
        #expect(held.allSatisfy { $0.method == .head && $0.url.absoluteString == "\(IdleCoordinator.base)/2" })
    }

    @Test("A server without the HEAD heartbeat gets the held page asked for again, and its rows are not read twice")
    func refusedHeadFallsBackToTheHeldPage() async throws {
        let transport = IdleCoordinator(headStatus: 405)
        let (rows, held) = try await read(transport, heartbeat: .head)
        #expect(rows == ["1", "2", "3"])
        #expect(held.first?.method == .head)
        #expect(held.dropFirst().allSatisfy { $0.method == .get && $0.url.absoluteString == "\(IdleCoordinator.base)/1" })
        #expect(held.filter { $0.method == .head }.count == 1)
    }

    @Test("A HEAD that a proxy refuses falls back to the held page for that beat and is tried again on the next")
    func refusedHeadBeatFallsBackOnce() async throws {
        let transport = IdleCoordinator(headStatus: 403)
        let (rows, held) = try await read(transport, heartbeat: .head)
        #expect(rows == ["1", "2", "3"])
        #expect(held.count == 80)
        #expect(held.enumerated().allSatisfy { index, request in
            index.isMultiple(of: 2)
                ? request.method == .head && request.url.absoluteString == "\(IdleCoordinator.base)/2"
                : request.method == .get && request.url.absoluteString == "\(IdleCoordinator.base)/1"
        })
    }

    @Test("Older Trino and Presto get the held page asked for again")
    func repeatLastPageHeartbeat() async throws {
        let transport = IdleCoordinator(headStatus: 200)
        let (rows, held) = try await read(transport, heartbeat: .repeatLastPage)
        #expect(rows == ["1", "2", "3"])
        #expect(held.count == 40)
        #expect(held.allSatisfy { $0.method == .get && $0.url.absoluteString == "\(IdleCoordinator.base)/1" })
    }

    @Test("Without heartbeats the coordinator abandons a query held past its client timeout")
    func heldPageWithoutHeartbeatsIsAbandoned() async {
        let transport = IdleCoordinator(headStatus: 200)
        await #expect {
            _ = try await read(transport, heartbeat: .head, sendsHeartbeats: false)
        } throws: { error in
            guard case TrinoError.query(let failure) = error else { return false }
            return failure.errorName == "ABANDONED_QUERY"
        }
    }

    @Test("A reader that stops taking pages ends the query on the coordinator", .timeLimit(.minutes(1)))
    func readerThatStopsSendsTheDelete() async {
        let transport = IdleCoordinator(headStatus: 200)
        await #expect(throws: CancellationError.self) {
            try await client(transport).executeStreamed(
                "SELECT n FROM t",
                heartbeat: .head,
                onColumns: { _ in },
                onPage: { _, _ in throw CancellationError() }
            )
        }
        var deletes = transport.deletes.stream.makeAsyncIterator()
        await deletes.next()
        #expect(transport.requests.filter { $0.method == .delete }.map(\.url.absoluteString) == ["\(IdleCoordinator.base)/1"])
    }

    @Test("HEAD heartbeats start at Trino 475", arguments: [
        (TrinoServerFlavor.trino, "475" as String?, TrinoHeartbeat.head),
        (.trino, "476-e.1", .head),
        (.trino, "474", .repeatLastPage),
        (.trino, nil, .repeatLastPage),
        (.presto, "0.300", .repeatLastPage)
    ])
    func heartbeatFollowsTheServer(flavor: TrinoServerFlavor, version: String?, expected: TrinoHeartbeat) {
        #expect(TrinoHeartbeat(flavor: flavor, version: version) == expected)
    }
}
