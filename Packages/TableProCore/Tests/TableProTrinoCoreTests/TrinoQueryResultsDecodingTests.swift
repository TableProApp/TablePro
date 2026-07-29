import XCTest
@testable import TableProTrinoCore

final class TrinoQueryResultsDecodingTests: XCTestCase {
    private func decode(_ json: String) throws -> TrinoQueryResults {
        try JSONDecoder().decode(TrinoQueryResults.self, from: Data(json.utf8))
    }

    func testDecodesInitialResponseWithoutColumns() throws {
        let json = #"{"id":"q1","infoUri":"http://h/ui/q1","nextUri":"http://h/v1/statement/q1/1","stats":{"state":"QUEUED"}}"#
        let results = try decode(json)
        XCTAssertEqual(results.id, "q1")
        XCTAssertEqual(results.nextUri, "http://h/v1/statement/q1/1")
        XCTAssertNil(results.columns)
        XCTAssertNil(results.data)
        XCTAssertNil(results.error)
        XCTAssertEqual(results.stats?.state, "QUEUED")
    }

    func testDecodesColumnsAndData() throws {
        let json = #"""
        {"id":"q1","columns":[{"name":"n","type":"bigint","typeSignature":{"rawType":"bigint"}},
        {"name":"s","type":"varchar(3)","typeSignature":{"rawType":"varchar"}}],
        "data":[[1,"abc"],[2,"xyz"]],"stats":{"state":"FINISHED"}}
        """#
        let results = try decode(json)
        XCTAssertEqual(results.columns?.count, 2)
        XCTAssertEqual(results.columns?.first?.name, "n")
        XCTAssertEqual(results.columns?.first?.rawTypeName, "bigint")
        XCTAssertEqual(results.columns?.last?.type, "varchar(3)")
        XCTAssertEqual(results.data?.count, 2)
    }

    func testDecodesErrorObject() throws {
        let json = #"""
        {"id":"q1","error":{"message":"line 1:1: Table not found","errorCode":46,
        "errorName":"TABLE_NOT_FOUND","errorType":"USER_ERROR"}}
        """#
        let results = try decode(json)
        XCTAssertEqual(results.error?.errorName, "TABLE_NOT_FOUND")
        XCTAssertEqual(results.error?.errorType, "USER_ERROR")
        XCTAssertEqual(results.error?.errorCode, 46)
        XCTAssertEqual(results.error?.message, "line 1:1: Table not found")
    }

    func testDecodesUpdateTypeAndCount() throws {
        let json = #"{"id":"q1","updateType":"INSERT","updateCount":7,"stats":{"state":"FINISHED"}}"#
        let results = try decode(json)
        XCTAssertEqual(results.updateType, "INSERT")
        XCTAssertEqual(results.updateCount, 7)
        XCTAssertNil(results.nextUri)
    }
}
