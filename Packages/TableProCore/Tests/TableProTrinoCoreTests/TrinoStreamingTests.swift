import XCTest
@testable import TableProTrinoCore

final class TrinoStreamingTests: XCTestCase {
    private let bigintColumn = #"{"name":"n","type":"bigint","typeSignature":{"rawType":"bigint"}}"#

    private func makeClient(_ transport: StubTransport) -> TrinoStatementClient {
        let config = TrinoClientConfig(host: "h", port: 8_080, user: "u")
        return TrinoStatementClient(transport: transport, config: config, session: TrinoSessionState(catalog: "c", schema: "s"))
    }

    func testStreamsColumnsOnceThenEachPageSeparately() async throws {
        let transport = StubTransport([
            canned(#"{"id":"q1","nextUri":"http://h:8080/v1/statement/q1/1"}"#),
            canned(#"{"id":"q1","nextUri":"http://h:8080/v1/statement/q1/2","columns":[\#(bigintColumn)]}"#),
            canned(#"{"id":"q1","nextUri":"http://h:8080/v1/statement/q1/3","columns":[\#(bigintColumn)],"data":[[1],[2]]}"#),
            canned(#"{"id":"q1","columns":[\#(bigintColumn)],"data":[[3]]}"#),
        ])
        let client = makeClient(transport)

        var columnBatches: [[TrinoColumnDescriptor]] = []
        var pages: [[[TrinoValue]]] = []
        for try await element in client.executeStreamed("SELECT n FROM t") {
            switch element {
            case .columns(let columns):
                columnBatches.append(columns)
            case .rows(let page):
                pages.append(page)
            }
        }

        XCTAssertEqual(columnBatches.count, 1)
        XCTAssertEqual(columnBatches.first?.map(\.name), ["n"])
        XCTAssertEqual(pages, [[[.text("1")], [.text("2")]], [[.text("3")]]])
    }

    func testStreamPropagatesQueryError() async throws {
        let transport = StubTransport([
            canned(#"{"id":"q1","error":{"message":"boom","errorName":"GENERIC_INTERNAL_ERROR","errorType":"INTERNAL_ERROR"}}"#),
        ])
        let client = makeClient(transport)

        do {
            for try await _ in client.executeStreamed("SELECT 1") {}
            XCTFail("Expected an error")
        } catch let error as TrinoError {
            guard case .query = error else {
                return XCTFail("Expected TrinoError.query, got \(error)")
            }
        }
    }
}
