import XCTest
@testable import TableProTrinoCore

final class TrinoStatementClientTests: XCTestCase {
    private func makeClient(_ transport: StubTransport, session: TrinoSessionState = TrinoSessionState(catalog: "c", schema: "s")) -> TrinoStatementClient {
        let config = TrinoClientConfig(host: "h", port: 8_080, user: "u")
        return TrinoStatementClient(transport: transport, config: config, session: session)
    }

    private let bigintColumn = #"{"name":"n","type":"bigint","typeSignature":{"rawType":"bigint"}}"#

    func testPollsNextUriUntilAbsentAndAccumulatesRows() async throws {
        let transport = StubTransport([
            canned(#"{"id":"q1","nextUri":"http://h:8080/v1/statement/q1/1"}"#),
            canned(#"{"id":"q1","nextUri":"http://h:8080/v1/statement/q1/2","columns":[\#(bigintColumn)]}"#),
            canned(#"{"id":"q1","nextUri":"http://h:8080/v1/statement/q1/3","columns":[\#(bigintColumn)],"data":[[9007199254740993]]}"#),
            canned(#"{"id":"q1","columns":[\#(bigintColumn)],"data":[[42]]}"#)
        ])
        let client = makeClient(transport)

        let result = try await client.execute("SELECT n FROM t")

        XCTAssertEqual(result.columns.map(\.name), ["n"])
        XCTAssertEqual(result.columns.first?.category, .scalar)
        XCTAssertEqual(result.rows, [[.text("9007199254740993")], [.text("42")]])
        XCTAssertEqual(transport.requests.count, 4)
        XCTAssertEqual(transport.requests.first?.method, .post)
        XCTAssertEqual(transport.requests.dropFirst().map(\.method), [.get, .get, .get])
    }

    func testInitialPostCarriesSessionHeaders() async throws {
        let transport = StubTransport([canned(#"{"id":"q1"}"#)])
        let client = makeClient(transport)

        _ = try await client.execute("SELECT 1")

        let post = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(post.headers["X-Trino-User"], "u")
        XCTAssertEqual(post.headers["X-Trino-Catalog"], "c")
        XCTAssertEqual(post.headers["X-Trino-Schema"], "s")
        XCTAssertEqual(post.headers["X-Trino-Source"], "TablePro")
        XCTAssertEqual(post.headers["Content-Type"], "text/plain; charset=utf-8")
        XCTAssertEqual(post.body, Data("SELECT 1".utf8))
    }

    func testThrowsOnQueryError() async throws {
        let transport = StubTransport([
            canned(#"{"id":"q1","error":{"message":"Table not found","errorName":"TABLE_NOT_FOUND","errorType":"USER_ERROR","errorCode":46}}"#)
        ])
        let client = makeClient(transport)

        do {
            _ = try await client.execute("SELECT * FROM missing")
            XCTFail("Expected a query error")
        } catch let error as TrinoError {
            guard case .query(let queryError) = error else {
                return XCTFail("Expected TrinoError.query, got \(error)")
            }
            XCTAssertEqual(queryError.errorName, "TABLE_NOT_FOUND")
            XCTAssertEqual(error.errorDescription, "TABLE_NOT_FOUND: Table not found")
        }
    }

    func testRetriesOnServiceUnavailable() async throws {
        let transport = StubTransport([
            canned("upstream unavailable", status: 503),
            canned(#"{"id":"q1","data":[]}"#)
        ])
        let client = makeClient(transport)

        _ = try await client.execute("SELECT 1")

        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests.map(\.method), [.post, .post])
    }

    func testThrowsAuthenticationFailedOn401() async throws {
        let transport = StubTransport([canned("Unauthorized", status: 401)])
        let client = makeClient(transport)

        do {
            _ = try await client.execute("SELECT 1")
            XCTFail("Expected an authentication error")
        } catch let error as TrinoError {
            guard case .authenticationFailed = error else {
                return XCTFail("Expected authenticationFailed, got \(error)")
            }
        }
    }

    func testReportsUpdateTypeAndCountForDML() async throws {
        let transport = StubTransport([canned(#"{"id":"q1","updateType":"INSERT","updateCount":5}"#)])
        let client = makeClient(transport)

        let result = try await client.execute("INSERT INTO t VALUES (1)")

        XCTAssertEqual(result.updateType, "INSERT")
        XCTAssertEqual(result.updateCount, 5)
        XCTAssertTrue(result.columns.isEmpty)
        XCTAssertTrue(result.rows.isEmpty)
    }

    func testAppliesResponseSessionHeadersToState() async throws {
        let session = TrinoSessionState(catalog: "c", schema: "s")
        let transport = StubTransport([
            canned(
                #"{"id":"q1","updateType":"SET SESSION"}"#,
                headers: ["X-Trino-Set-Catalog": "hive", "X-Trino-Set-Schema": "analytics"]
            )
        ])
        let client = makeClient(transport, session: session)

        _ = try await client.execute("USE hive.analytics")

        XCTAssertEqual(session.catalog, "hive")
        XCTAssertEqual(session.schema, "analytics")
    }

    func testCancelStopsPolling() async throws {
        let box = ClientBox()
        let transport = StubTransport([
            canned(#"{"id":"q1","nextUri":"http://h:8080/v1/statement/q1/1"}"#),
            canned(#"{"id":"q1","nextUri":"http://h:8080/v1/statement/q1/2"}"#)
        ])
        transport.onSend = { _, index in
            if index == 1 {
                box.client?.cancel()
            }
        }
        let client = makeClient(transport)
        box.client = client

        do {
            _ = try await client.execute("SELECT 1")
            XCTFail("Expected cancellation")
        } catch let error as TrinoError {
            XCTAssertEqual(error, .cancelled)
        }
    }
}
