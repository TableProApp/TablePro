import Foundation
@testable import TableProMobile
import TableProModels
import Testing

@Suite("Redis query result builder")
struct RedisQueryResultBuilderTests {
    private func build(_ reply: RedisReplyValue) throws -> QueryResult {
        try RedisQueryResultBuilder.result(for: reply, executionTime: 0.25)
    }

    @Test("an error reply throws instead of filling a result")
    func errorReplyThrows() {
        let message = "ERR unknown command 'DELETE', with args beginning with: 'FROM'"
        #expect(throws: RedisError.queryFailed(message)) {
            try build(.error(message))
        }
    }

    @Test("a QUEUED status is a result")
    func queuedStatusIsAResult() throws {
        let result = try build(.status("QUEUED"))
        #expect(result.columns.map(\.name) == ["status"])
        #expect(result.rows == [["QUEUED"]])
        #expect(result.statusMessage == "QUEUED")
    }

    @Test("an EXEC array marks its inline error")
    func execArrayMarksInlineError() throws {
        let result = try build(.array([.status("OK"), .error("ERR value is not an integer or out of range")]))
        #expect(result.columns.map(\.name) == ["index", "value"])
        #expect(result.rows == [["0", "OK"], ["1", "(error) ERR value is not an integer or out of range"]])
    }

    @Test("a bulk string is one value row")
    func bulkString() throws {
        let result = try build(.string("ada"))
        #expect(result.columns.map(\.name) == ["value"])
        #expect(result.columns.map(\.typeName) == ["string"])
        #expect(result.rows == [["ada"]])
        #expect(result.statusMessage == nil)
        #expect(result.executionTime == 0.25)
    }

    @Test("an integer is one value row typed integer")
    func integer() throws {
        let result = try build(.integer(42))
        #expect(result.columns.map(\.typeName) == ["integer"])
        #expect(result.rows == [["42"]])
    }

    @Test("a nil reply is one null value row")
    func null() throws {
        let result = try build(.null)
        #expect(result.columns.map(\.name) == ["value"])
        #expect(result.rows == [[nil]])
    }

    @Test("an array with a non-string at an even position reads by index")
    func indexedArray() throws {
        let result = try build(.array([.integer(1), .string("b"), .null]))
        #expect(result.columns.map(\.name) == ["index", "value"])
        #expect(result.rows == [["0", "1"], ["1", "b"], ["2", nil]])
        #expect(!result.isTruncated)
    }

    @Test("an even array of strings reads as field and value pairs")
    func pairedArray() throws {
        let result = try build(.array([.string("name"), .string("ada"), .string("age"), .integer(36)]))
        #expect(result.columns.map(\.name) == ["key", "value"])
        #expect(result.rows == [["name", "ada"], ["age", "36"]])
    }

    @Test("an empty array has no rows")
    func emptyArray() throws {
        let result = try build(.array([]))
        #expect(result.columns.map(\.name) == ["index", "value"])
        #expect(result.rows.isEmpty)
    }

    @Test("an indexed array past the row limit is cut and marked truncated")
    func truncatesLongArrays() throws {
        let items = Array(repeating: RedisReplyValue.integer(1), count: RedisQueryResultBuilder.rowLimit + 1)
        let result = try build(.array(items))
        #expect(result.rows.count == RedisQueryResultBuilder.rowLimit)
        #expect(result.isTruncated)
    }
}
