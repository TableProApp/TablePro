import Foundation
import Testing

@testable import TableProSpannerCore

@Suite("SpannerRESTClient")
struct SpannerRESTClientTests {
    private static let session = SpannerTestFixtures.sessionName
    private static let productionBase = "https://spanner.googleapis.com/v1/"
    private static let unavailable = #"{"error":{"code":503,"message":"The service is unavailable.","status":"UNAVAILABLE"}}"#
    private static let exhausted = #"{"error":{"code":429,"message":"Quota exceeded.","status":"RESOURCE_EXHAUSTED"}}"#

    private func productionClient(
        _ transport: StubSpannerTransport,
        tokens: StubAccessTokenProvider? = StubAccessTokenProvider(tokens: ["tok"])
    ) throws -> SpannerRESTClient {
        SpannerTestFixtures.client(transport: transport, settings: try SpannerTestFixtures.settings(), tokenProvider: tokens)
    }

    @Test("Database dialect comes from GET on the database")
    func dialect() async throws {
        let transport = StubSpannerTransport([.json(#"{"name":"x","state":"READY","databaseDialect":"POSTGRESQL"}"#)])
        let dialect = try await productionClient(transport).databaseDialect()
        #expect(dialect == "POSTGRESQL")
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.absoluteURL == Self.productionBase + SpannerTestFixtures.databasePath)
        #expect(request.httpBody == nil)
    }

    @Test("Create session posts labels and the multiplexed flag, and returns the full name")
    func createSession() async throws {
        let transport = StubSpannerTransport([
            .json(#"{"name":"projects/proj/instances/inst/databases/gdb/sessions/18","multiplexed":true}"#),
            .json(#"{"name":"projects/proj/instances/inst/databases/gdb/sessions/19"}"#)
        ])
        let client = try productionClient(transport)
        #expect(try await client.createSession(multiplexed: true) == "projects/proj/instances/inst/databases/gdb/sessions/18")
        #expect(try await client.createSession(multiplexed: false) == "projects/proj/instances/inst/databases/gdb/sessions/19")
        let requests = transport.requests
        #expect(requests[0].httpMethod == "POST")
        #expect(requests[0].absoluteURL == Self.productionBase + SpannerTestFixtures.databasePath + "/sessions")
        let multiplexed = try #require(requests[0].jsonBody?["session"] as? [String: Any])
        #expect(multiplexed["multiplexed"] as? Bool == true)
        #expect(multiplexed["labels"] as? [String: String] == ["app": "tablepro"])
        let regular = try #require(requests[1].jsonBody?["session"] as? [String: Any])
        #expect(regular["multiplexed"] == nil)
    }

    @Test("A session response without a name is invalid")
    func createSessionWithoutName() async throws {
        let transport = StubSpannerTransport([.json("{}")])
        await #expect(throws: SpannerTransportError.invalidResponse) {
            try await productionClient(transport).createSession(multiplexed: true)
        }
    }

    @Test("Session endpoints append the verb to the session resource")
    func sessionEndpoints() async throws {
        let transport = StubSpannerTransport([
            .json(#"{"id":"TXN"}"#),
            .json(#"{"commitTimestamp":"2026-01-01T00:00:00Z"}"#),
            .json("{}"),
            .json("{}")
        ])
        let client = try productionClient(transport)
        #expect(try await client.beginTransaction(session: Self.session) == "TXN")
        try await client.commit(session: Self.session, transactionId: "TXN")
        try await client.rollback(session: Self.session, transactionId: "TXN2")
        try await client.deleteSession(Self.session)
        let requests = transport.requests
        #expect(requests.map(\.absoluteURL) == [
            Self.productionBase + Self.session + ":beginTransaction",
            Self.productionBase + Self.session + ":commit",
            Self.productionBase + Self.session + ":rollback",
            Self.productionBase + Self.session
        ])
        #expect(requests.map(\.httpMethod) == ["POST", "POST", "POST", "DELETE"])
        let options = try #require(requests[0].jsonBody?["options"] as? [String: Any])
        #expect(options["readWrite"] is [String: Any])
        #expect(requests[1].jsonBody?["transactionId"] as? String == "TXN")
        #expect(requests[2].jsonBody?["transactionId"] as? String == "TXN2")
    }

    @Test("executeSql decodes the result set")
    func executeSql() async throws {
        let transport = StubSpannerTransport([
            .json(#"{"metadata":{"rowType":{"fields":[{"type":{"code":"INT64"}}]}},"rows":[["1"]]}"#)
        ])
        let result = try await productionClient(transport).executeSql(
            session: Self.session,
            SpannerExecuteSqlRequest(sql: "SELECT 1", transaction: .singleUseStrongReadOnly)
        )
        #expect(result.rows == [[.string("1")]])
        let request = try #require(transport.requests.first)
        #expect(request.absoluteURL == Self.productionBase + Self.session + ":executeSql")
        #expect(request.jsonBody?["sql"] as? String == "SELECT 1")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test("A malformed success body is an invalid response")
    func malformedSuccess() async throws {
        let transport = StubSpannerTransport([.json("not json")])
        await #expect(throws: SpannerTransportError.invalidResponse) {
            try await productionClient(transport).executeSql(
                session: Self.session,
                SpannerExecuteSqlRequest(sql: "SELECT 1", transaction: .singleUseStrongReadOnly)
            )
        }
    }

    @Test("DDL, operations and the DDL listing use the database admin paths")
    func adminEndpoints() async throws {
        let operationName = "projects/proj/instances/inst/databases/gdb/operations/_auto7"
        let transport = StubSpannerTransport([
            .json(#"{"name":"\#(operationName)","done":false}"#),
            .json(#"{"name":"\#(operationName)","done":true,"error":{"code":5,"message":"Table not found: x"}}"#),
            .json(#"{"statements":["CREATE SCHEMA sales","CREATE TABLE t (id INT64) PRIMARY KEY(id)"]}"#)
        ])
        let client = try productionClient(transport)
        let started = try await client.updateDdl(["CREATE TABLE t (id INT64) PRIMARY KEY(id)"])
        #expect(started == SpannerOperation(name: operationName, done: false, error: nil))
        let finished = try await client.operation(named: operationName)
        #expect(finished.done)
        #expect(finished.error?.isNotFound == true)
        #expect(finished.error?.message == "Table not found: x")
        #expect(try await client.databaseDDL().count == 2)
        let requests = transport.requests
        #expect(requests[0].httpMethod == "PATCH")
        #expect(requests[0].absoluteURL == Self.productionBase + SpannerTestFixtures.databasePath + "/ddl")
        #expect(requests[0].jsonBody?["statements"] as? [String] == ["CREATE TABLE t (id INT64) PRIMARY KEY(id)"])
        #expect(requests[1].httpMethod == "GET")
        #expect(requests[1].absoluteURL == Self.productionBase + operationName)
        #expect(requests[2].absoluteURL == Self.productionBase + SpannerTestFixtures.databasePath + "/ddl")
    }

    @Test("A bearer token goes to a trusted Google endpoint")
    func bearerForGoogle() async throws {
        let transport = StubSpannerTransport([.json(#"{"databaseDialect":"GOOGLE_STANDARD_SQL"}"#)])
        _ = try await productionClient(transport).databaseDialect()
        #expect(transport.requests.first?.authorization == "Bearer tok")
    }

    @Test("No Authorization header reaches a loopback endpoint even with a provider")
    func noBearerForLoopback() async throws {
        let transport = StubSpannerTransport([.json(#"{"databaseDialect":"GOOGLE_STANDARD_SQL"}"#)])
        let tokens = StubAccessTokenProvider(tokens: ["tok"])
        let client = SpannerTestFixtures.client(
            transport: transport,
            settings: try SpannerTestFixtures.emulatorSettings(),
            tokenProvider: tokens
        )
        _ = try await client.databaseDialect()
        #expect(transport.requests.first?.authorization == nil)
        #expect(transport.requests.first?.absoluteURL == "http://localhost:9020/v1/" + SpannerTestFixtures.databasePath)
        #expect(await tokens.accessTokenCalls == 0)
    }

    @Test("Without a provider no Authorization header is sent")
    func noProvider() async throws {
        let transport = StubSpannerTransport([.json("{}")])
        _ = try await productionClient(transport, tokens: nil).databaseDialect()
        #expect(transport.requests.first?.authorization == nil)
    }

    @Test("A 401 invalidates the cached token and retries once with a fresh one")
    func unauthorizedRetriesOnce() async throws {
        let transport = StubSpannerTransport([
            .json(#"{"error":{"code":401,"message":"expired","status":"UNAUTHENTICATED"}}"#, status: 401),
            .json(#"{"databaseDialect":"POSTGRESQL"}"#)
        ])
        let tokens = StubAccessTokenProvider(tokens: ["old", "new"])
        let dialect = try await productionClient(transport, tokens: tokens).databaseDialect()
        #expect(dialect == "POSTGRESQL")
        #expect(transport.requests.map(\.authorization) == ["Bearer old", "Bearer new"])
        #expect(await tokens.invalidations == 1)
    }

    @Test("A second 401 is surfaced as unauthenticated")
    func unauthorizedTwice() async throws {
        let body = #"{"error":{"code":401,"message":"bad","status":"UNAUTHENTICATED"}}"#
        let transport = StubSpannerTransport([.json(body, status: 401), .json(body, status: 401)])
        let tokens = StubAccessTokenProvider(tokens: ["a", "b"])
        do {
            _ = try await productionClient(transport, tokens: tokens).databaseDialect()
            Issue.record("Expected an unauthenticated error")
        } catch let error as SpannerAPIError {
            #expect(error.isUnauthenticated)
        }
        #expect(transport.requests.count == 2)
        #expect(await tokens.invalidations == 1)
    }

    @Test("UNAVAILABLE is retried for a replay-safe request")
    func unavailableRetried() async throws {
        let transport = StubSpannerTransport([
            .json(Self.unavailable, status: 503),
            .json(Self.unavailable, status: 503),
            .json(#"{"metadata":{"rowType":{"fields":[]}}}"#)
        ])
        _ = try await productionClient(transport).executeSql(
            session: Self.session,
            SpannerExecuteSqlRequest(sql: "SELECT 1", transaction: .singleUseStrongReadOnly)
        )
        #expect(transport.requests.count == 3)
    }

    @Test("A network failure is retried for a replay-safe request")
    func networkRetried() async throws {
        let transport = StubSpannerTransport([
            .failing(.network("networkConnectionLost")),
            .json(#"{"name":"projects/proj/instances/inst/databases/gdb/sessions/1"}"#)
        ])
        _ = try await productionClient(transport).createSession(multiplexed: true)
        #expect(transport.requests.count == 2)
    }

    @Test("Retries stop after the backoff schedule is spent")
    func retriesBounded() async throws {
        let transport = StubSpannerTransport(Array(repeating: .json(Self.unavailable, status: 503), count: 10))
        do {
            _ = try await productionClient(transport).databaseDDL()
            Issue.record("Expected UNAVAILABLE")
        } catch let error as SpannerAPIError {
            #expect(error.isUnavailable)
        }
        #expect(transport.requests.count == 4)
    }

    @Test("A request that is not replay-safe is never retried")
    func notReplaySafe() async throws {
        let transport = StubSpannerTransport([
            .json(Self.unavailable, status: 503),
            .json(Self.unavailable, status: 503),
            .json("{}")
        ])
        await #expect(throws: SpannerAPIError.self) {
            try await productionClient(transport).executeSql(
                session: Self.session,
                SpannerExecuteSqlRequest(sql: "SELECT 1", transaction: .id("TXN"))
            )
        }
        await #expect(throws: SpannerAPIError.self) {
            try await productionClient(transport).updateDdl(["DROP TABLE t"])
        }
        #expect(transport.requests.count == 2)
    }

    @Test("DML carrying a seqno is replay-safe")
    func dmlWithSeqnoRetried() async throws {
        let transport = StubSpannerTransport([
            .json(Self.unavailable, status: 503),
            .json(#"{"metadata":{"rowType":{}},"stats":{"rowCountExact":"1"}}"#)
        ])
        let result = try await productionClient(transport).executeSql(
            session: Self.session,
            SpannerExecuteSqlRequest(sql: "DELETE FROM t WHERE TRUE", transaction: .id("TXN"), seqno: 4)
        )
        #expect(result.stats?.rowCountExact == 1)
        #expect(transport.requests.count == 2)
    }

    @Test("RESOURCE_EXHAUSTED (429) is never retried")
    func exhaustedNotRetried() async throws {
        let transport = StubSpannerTransport([.json(Self.exhausted, status: 429), .json("{}")])
        do {
            _ = try await productionClient(transport).executeSql(
                session: Self.session,
                SpannerExecuteSqlRequest(sql: "SELECT 1", transaction: .singleUseStrongReadOnly)
            )
            Issue.record("Expected RESOURCE_EXHAUSTED")
        } catch let error as SpannerAPIError {
            #expect(error.httpStatus == 429)
            #expect(error.status == "RESOURCE_EXHAUSTED")
        }
        #expect(transport.requests.count == 1)
    }

    @Test("Cancellation and timeouts are not retried")
    func cancellationNotRetried() async throws {
        let transport = StubSpannerTransport([.failing(.cancelled), .failing(.timedOut), .json("{}")])
        let client = try productionClient(transport)
        await #expect(throws: SpannerTransportError.cancelled) {
            try await client.databaseDialect()
        }
        await #expect(throws: SpannerTransportError.timedOut) {
            try await client.databaseDialect()
        }
        #expect(transport.requests.count == 2)
    }

    @Test("A streaming query yields metadata once, merged rows and final stats")
    func streamingQuery() async throws {
        let transport = StubSpannerTransport([.stream([
            #"[{"metadata":{"rowType":{"fields":[{"name":"s","type":{"code":"STRING"}}]}},"values":["ab"],"chunkedValue":true}"#,
            #",{"values":["c","d"]},{"values":[],"stats":{"rowCountExact":"2"}}]"#
        ])])
        let stream = try await productionClient(transport).executeStreamingSql(
            session: Self.session,
            SpannerExecuteSqlRequest(sql: "SELECT s FROM t", transaction: .singleUseStrongReadOnly)
        )
        let events = try await collectEvents(stream)
        #expect(transport.requests.first?.absoluteURL == Self.productionBase + Self.session + ":executeStreamingSql")
        guard case .metadata(let metadata) = events.first else {
            Issue.record("Metadata must come first")
            return
        }
        #expect(metadata.fields.map(\.name) == ["s"])
        #expect(events.filter { if case .metadata = $0 { return true } else { return false } }.count == 1)
        #expect(streamedRows(events) == [[.string("abc")], [.string("d")]])
        guard case .stats(let stats) = events.last else {
            Issue.record("Stats must come last")
            return
        }
        #expect(stats.rowCountExact == 2)
    }

    @Test("The emulator's NDJSON stream split at every byte decodes the same rows")
    func streamingNDJSONByteSplit() async throws {
        let body = """
        {"result":{"metadata":{"rowType":{"fields":[{"name":"a","type":{"code":"INT64"}},{"name":"b","type":{"code":"STRING"}}]}},"values":["2","y","1","x"]}}

        """
        let transport = StubSpannerTransport([.stream(body.map { String($0) })])
        let stream = try await SpannerTestFixtures.emulatorClient(transport: transport).executeStreamingSql(
            session: Self.session,
            SpannerExecuteSqlRequest(sql: "SELECT", transaction: .singleUseStrongReadOnly)
        )
        let events = try await collectEvents(stream)
        #expect(streamedRows(events) == [[.string("2"), .string("y")], [.string("1"), .string("x")]])
    }

    @Test("An in-stream error throws after the rows before it")
    func streamingInStreamError() async throws {
        let transport = StubSpannerTransport([.stream([
            #"{"result":{"metadata":{"rowType":{"fields":[{"name":"a","type":{"code":"INT64"}}]}},"values":["1"]}}"#,
            "\n",
            #"{"error":{"code":10,"message":"Transaction was aborted.","status":"ABORTED"}}"#
        ])])
        let stream = try await productionClient(transport).executeStreamingSql(
            session: Self.session,
            SpannerExecuteSqlRequest(sql: "SELECT a FROM t", transaction: .id("TXN"))
        )
        var rows: [[SpannerJSONValue]] = []
        do {
            for try await event in stream {
                if case .rows(let batch) = event {
                    rows += batch
                }
            }
            Issue.record("Expected the in-stream error")
        } catch let error as SpannerAPIError {
            #expect(error.isAborted)
        }
        #expect(rows == [[.string("1")]])
    }

    @Test("A non-2xx stream head throws the decoded error before any event")
    func streamingErrorHead() async throws {
        let transport = StubSpannerTransport([
            .stream([#"{"error":{"code":11,"message":"Output of REPEAT exceeds max allowed output size of 1MB"}}"#], status: 400)
        ])
        do {
            _ = try await productionClient(transport).executeStreamingSql(
                session: Self.session,
                SpannerExecuteSqlRequest(sql: "SELECT", transaction: .singleUseStrongReadOnly)
            )
            Issue.record("Expected the head error")
        } catch let error as SpannerAPIError {
            #expect(error.httpStatus == 400)
            #expect(error.code == 11)
        }
    }

    @Test("A stream head with an empty error body keeps the HTTP status")
    func streamingEmptyErrorBody() async throws {
        let transport = StubSpannerTransport([.stream([], status: 400)])
        do {
            _ = try await productionClient(transport).executeStreamingSql(
                session: Self.session,
                SpannerExecuteSqlRequest(sql: "SELECT", transaction: .singleUseStrongReadOnly)
            )
            Issue.record("Expected the head error")
        } catch let error as SpannerAPIError {
            #expect(error.message == "HTTP 400")
        }
    }

    @Test("A streaming 401 refreshes the token once before any event")
    func streamingUnauthorized() async throws {
        let transport = StubSpannerTransport([
            .stream([#"{"error":{"code":401,"message":"expired","status":"UNAUTHENTICATED"}}"#], status: 401),
            .stream([#"[{"metadata":{"rowType":{"fields":[{"name":"a","type":{"code":"INT64"}}]}},"values":["1"]}]"#])
        ])
        let tokens = StubAccessTokenProvider(tokens: ["old", "new"])
        let stream = try await productionClient(transport, tokens: tokens).executeStreamingSql(
            session: Self.session,
            SpannerExecuteSqlRequest(sql: "SELECT", transaction: .singleUseStrongReadOnly)
        )
        #expect(streamedRows(try await collectEvents(stream)) == [[.string("1")]])
        #expect(transport.requests.map(\.authorization) == ["Bearer old", "Bearer new"])
        #expect(await tokens.invalidations == 1)
    }

    @Test("A streaming UNAVAILABLE head is not retried")
    func streamingNotRetried() async throws {
        let transport = StubSpannerTransport([.stream([Self.unavailable], status: 503)])
        await #expect(throws: SpannerAPIError.self) {
            try await productionClient(transport).executeStreamingSql(
                session: Self.session,
                SpannerExecuteSqlRequest(sql: "SELECT", transaction: .singleUseStrongReadOnly)
            )
        }
        #expect(transport.requests.count == 1)
    }

    @Test("A truncated stream fails instead of dropping the partial row")
    func streamingTruncated() async throws {
        let transport = StubSpannerTransport([.stream([
            #"[{"metadata":{"rowType":{"fields":[{"name":"a","type":{"code":"STRING"}}]}},"values":["ab"],"chunkedValue":true}"#
        ])])
        let stream = try await productionClient(transport).executeStreamingSql(
            session: Self.session,
            SpannerExecuteSqlRequest(sql: "SELECT", transaction: .singleUseStrongReadOnly)
        )
        await #expect(throws: SpannerTransportError.invalidResponse) {
            _ = try await collectEvents(stream)
        }
    }

    @Test("A transport failure mid-stream surfaces from the event stream")
    func streamingTransportFailure() async throws {
        let transport = StubSpannerTransport([.stream(
            [#"[{"metadata":{"rowType":{"fields":[{"name":"a","type":{"code":"INT64"}}]}},"values":["1"]}"#],
            trailingFailure: .network("networkConnectionLost")
        )])
        let stream = try await productionClient(transport).executeStreamingSql(
            session: Self.session,
            SpannerExecuteSqlRequest(sql: "SELECT", transaction: .singleUseStrongReadOnly)
        )
        await #expect(throws: SpannerTransportError.network("networkConnectionLost")) {
            _ = try await collectEvents(stream)
        }
    }

    @Test("Closing the client closes its transport")
    func closeClosesTransport() async throws {
        let transport = StubSpannerTransport()
        try await productionClient(transport).close()
        #expect(transport.closeCount == 1)
    }

    @Test("The URLSession transport refuses work once closed")
    func urlSessionClosed() async throws {
        let transport = URLSessionSpannerTransport(requestTimeout: { 5 })
        await transport.close()
        await transport.close()
        let request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:9/v1/x")))
        await #expect(throws: SpannerTransportError.closed) {
            try await transport.send(request)
        }
        await #expect(throws: SpannerTransportError.closed) {
            try await transport.stream(request)
        }
    }

    @Test("A cancelled caller never starts a URLSession request")
    func urlSessionCancelledBeforeStart() async throws {
        let transport = URLSessionSpannerTransport(requestTimeout: { 5 })
        let request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:9/v1/x")))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await transport.send(request)
        }
        let result = await task.result
        switch result {
        case .success:
            Issue.record("A cancelled send must not succeed")
        case .failure(let error):
            #expect(error is CancellationError || (error as? SpannerTransportError) == .cancelled)
        }
        await transport.close()
    }
}
