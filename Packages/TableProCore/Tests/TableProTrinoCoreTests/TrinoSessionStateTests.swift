import XCTest
@testable import TableProTrinoCore

final class TrinoSessionStateTests: XCTestCase {
    func testAppliesSetCatalogAndSchema() {
        let session = TrinoSessionState(catalog: "old", schema: "public")
        let headers = TrinoHeaderFields([
            "X-Trino-Set-Catalog": "hive",
            "X-Trino-Set-Schema": "analytics"
        ])
        session.apply(responseHeaders: headers, protocolHeaders: .trino)
        XCTAssertEqual(session.catalog, "hive")
        XCTAssertEqual(session.schema, "analytics")
    }

    func testAppliesSetAndClearSession() {
        let session = TrinoSessionState(sessionProperties: ["stale": "1"])
        let setHeaders = TrinoHeaderFields([
            "X-Trino-Set-Session": "query_max_memory=1GB",
            "X-Trino-Clear-Session": "stale"
        ])
        session.apply(responseHeaders: setHeaders, protocolHeaders: .trino)
        XCTAssertEqual(session.sessionProperties["query_max_memory"], "1GB")
        XCTAssertNil(session.sessionProperties["stale"])
    }

    func testDecodesPercentEncodedSessionValue() {
        let session = TrinoSessionState()
        let headers = TrinoHeaderFields(["X-Trino-Set-Session": "note=hello%20world"])
        session.apply(responseHeaders: headers, protocolHeaders: .trino)
        XCTAssertEqual(session.sessionProperties["note"], "hello world")
    }

    func testAppliesTransactionLifecycle() {
        let session = TrinoSessionState()
        session.apply(
            responseHeaders: TrinoHeaderFields(["X-Trino-Started-Transaction-Id": "tx-123"]),
            protocolHeaders: .trino
        )
        XCTAssertEqual(session.transactionId, "tx-123")
        session.apply(
            responseHeaders: TrinoHeaderFields(["X-Trino-Clear-Transaction-Id": "true"]),
            protocolHeaders: .trino
        )
        XCTAssertNil(session.transactionId)
    }

    func testSessionPropertyHeaderValueEncodesAndSorts() {
        let session = TrinoSessionState(sessionProperties: ["b": "2", "a": "hello world"])
        XCTAssertEqual(session.sessionPropertyHeaderValue(), "a=hello%20world,b=2")
    }

    func testPrestoProtocolHeadersApply() {
        let session = TrinoSessionState()
        session.apply(
            responseHeaders: TrinoHeaderFields(["X-Presto-Set-Catalog": "tpch"]),
            protocolHeaders: .presto
        )
        XCTAssertEqual(session.catalog, "tpch")
    }
}
