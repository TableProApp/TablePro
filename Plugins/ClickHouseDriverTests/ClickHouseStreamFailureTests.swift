//
//  ClickHouseStreamFailureTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

/// Bodies as the servers wrote them when `SELECT number, throwIf(number = 100000) FROM
/// numbers(200000)` failed after HTTP 200, measured on 23.8.8.20, 25.8.33.6 and 26.3.52.9.
struct ClickHouseStreamFailureTests {
    private static let twoColumnHeader = "number\tthrowIf(equals(number, 100000))\nUInt64\tUInt8\n"
    private static let oneColumnHeader = "toString(number)\nString\n"

    private static func rows(_ count: Int, columns: Int = 2) -> String {
        (0..<count).map { columns == 2 ? "\($0)\t0\n" : "\($0)\n" }.joined()
    }

    private static let throwIfMessage = "Code: 395. DB::Exception: Value passed to 'throwIf' function is non-zero: "
        + "while executing 'FUNCTION throwIf(equals(number, 100000) :: 2) -> throwIf(equals(number, 100000)) UInt8 : 1'. "
        + "(FUNCTION_THROW_IF_VALUE_IS_NON_ZERO)"

    /// Runs a body through the tail and the decoder in chunks, the way `streamTabSeparatedRows` does.
    private static func decode(
        _ body: String,
        tag: String? = nil,
        chunkSize: Int = 8_192
    ) throws -> [[PluginCellValue]] {
        var decoder = ClickHouseTabSeparatedRowDecoder()
        var tail = ClickHouseStreamTail()
        var rows: [[PluginCellValue]] = []
        let bytes = Data(body.utf8)
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunkSize, bytes.count)
            rows += decoder.consume(tail.release(bytes.subdata(in: offset..<end)))
            offset = end
        }
        rows += decoder.consume(try tail.finish(exceptionTag: tag, header: decoder.header))
        rows += decoder.finish()
        return rows
    }

    private static func failure(_ body: String, tag: String? = nil) -> String? {
        do {
            _ = try decode(body, tag: tag)
            return nil
        } catch let error as ClickHouseError {
            return error.message
        } catch {
            return "\(error)"
        }
    }

    @Test("23.8: the raw line after the last row is the error")
    func rawLineBefore2411() {
        let message = "\(Self.throwIfMessage) (version 23.8.8.20 (official build))"
        let body = Self.twoColumnHeader + Self.rows(3_000) + message + "\n"
        #expect(Self.failure(body) == message)
    }

    @Test("23.8: a multi-line message still has the wrong width for the result")
    func multiLineRawMessage() {
        let message = "Code: 395. DB::Exception: line1\nline2\ttabbed: while executing. (FUNCTION_THROW_IF_VALUE_IS_NON_ZERO) "
            + "(version 23.8.8.20 (official build))"
        let body = Self.twoColumnHeader + Self.rows(10) + message + "\n"
        #expect(Self.failure(body) == message)
    }

    @Test("23.8: a one-column String result with a raw quote in the tail is the error")
    func rawLineInOneColumnResult() {
        let message = "\(Self.throwIfMessage) (version 23.8.8.20 (official build))"
        let body = Self.oneColumnHeader + Self.rows(10, columns: 1) + message + "\n"
        #expect(Self.failure(body) == message)
    }

    /// `SELECT exception FROM system.query_log` returns exception text as values, and
    /// TabSeparated escapes their quotes.
    @Test("Exception text stored as a String value stays a row")
    func storedExceptionTextIsARow() throws {
        let value = #"Code: 60. DB::Exception: Table default.x doesn\'t exist. (UNKNOWN_TABLE) (version 23.8.8.20 (official build))"#
        let rows = try Self.decode("exception\nString\n" + value + "\n")
        #expect(rows == [[.text("Code: 60. DB::Exception: Table default.x doesn't exist. (UNKNOWN_TABLE) (version 23.8.8.20 (official build))")]])
    }

    @Test("Exception text stored as a String value stays a row with CRLF line ends too")
    func storedExceptionTextIsARowInCRLFMode() throws {
        let value = #"Code: 60. DB::Exception: Table default.x doesn\'t exist. (UNKNOWN_TABLE) (version 23.8.8.20 (official build))"#
        let rows = try Self.decode("exception\r\nString\r\n" + value + "\r\n")
        #expect(rows.count == 1)
    }

    @Test("A row that reads Code: without a version suffix stays a row")
    func codeTextWithoutVersionIsARow() throws {
        let rows = try Self.decode("s\nString\nCode: 1. DB::Exception: x\n")
        #expect(rows == [[.text("Code: 1. DB::Exception: x")]])
    }

    @Test("24.11 to 25.10: the marker and the text after it are the error")
    func untaggedMarker() {
        let message = "\(Self.throwIfMessage) (version 25.8.33.6 (official build))"
        let body = Self.twoColumnHeader + Self.rows(3_000) + "__exception__\r\n" + message + "\n"
        #expect(Self.failure(body) == message)
    }

    @Test("The value __exception__ stays a row: TabSeparated never writes a raw carriage return")
    func markerTextAsValueIsARow() throws {
        let rows = try Self.decode("s\nString\n__exception__\n")
        #expect(rows == [[.text("__exception__")]])
    }

    @Test("With CRLF line ends the marker line is a row, not the error")
    func crlfModeKeepsTheValue() throws {
        let rows = try Self.decode("s\r\nString\r\n__exception__\r\n")
        #expect(rows.count == 1)
    }

    @Test("25.11 on: the tagged block is the error, its length line and closing marker are not")
    func taggedBlock() {
        let tag = "abkxtrlzqztxfthi"
        let message = "Code: 395. DB::Exception: line1\nline2\ttabbed: while executing. (version 26.3.52.9 (official build))"
        let body = Self.twoColumnHeader + Self.rows(3_000)
            + "\r\n__exception__\r\n\(tag)\r\n\(message)\n\(message.utf8.count + 1) \(tag)\r\n__exception__\r\n"
        #expect(Self.failure(body, tag: tag) == message)
    }

    @Test("A tag on a body with no block is a normal result")
    func tagWithoutBlock() throws {
        let rows = try Self.decode(Self.twoColumnHeader + Self.rows(5), tag: "abkxtrlzqztxfthi")
        #expect(rows.count == 5)
    }

    @Test("A body that ends inside a row was cut off and is reported, not decoded as a row")
    func cutBody() {
        let body = Self.twoColumnHeader + Self.rows(10) + "286719\tRJ7Ml"
        #expect(Self.failure(body)?.contains("partway") == true)
    }

    @Test("A long result is released as it arrives and still ends in the error")
    func longBodyReleasesRows() throws {
        var decoder = ClickHouseTabSeparatedRowDecoder()
        var tail = ClickHouseStreamTail()
        let body = Data((Self.twoColumnHeader + Self.rows(50_000)).utf8)
        let released = decoder.consume(tail.release(body))
        #expect(released.count > 30_000)
        let rest = try tail.finish(exceptionTag: nil, header: decoder.header)
        #expect(released.count + decoder.consume(rest).count == 50_000)
    }

    @Test("A failure body keeps the text after any rows the server wrote ahead of it")
    func failureBodyMessage() {
        let message = "\(Self.throwIfMessage) (version 25.10.7.6 (official build))"
        #expect(ClickHouseServerException.message(inFailureBody: Self.twoColumnHeader + Self.rows(20) + message + "\n") == message)
        #expect(ClickHouseServerException.message(inFailureBody: "Bad Gateway\n") == "Bad Gateway")
    }

    @Test("A stream that ends in the marker throws instead of returning rows")
    func streamThrowsThroughTheDriver() async throws {
        let message = "\(Self.throwIfMessage) (version 25.8.33.6 (official build))"
        let server = ClickHouseStubServer { _ in
            ClickHouseStubReply(
                statusCode: 200,
                body: Self.twoColumnHeader + Self.rows(10) + "__exception__\r\n" + message + "\n",
                headers: ["X-ClickHouse-Format": "TabSeparatedWithNamesAndTypes"]
            )
        }
        let driver = server.connectedDriver()

        await #expect(throws: ClickHouseError.self) {
            for try await _ in driver.streamRows(query: "SELECT number FROM numbers(200000)") {}
        }
    }

    @Test("A capped read whose query names another format comes back as one Output value")
    func otherFormatIsOneValue() async throws {
        let json = #"{"meta": [{"name": "a", "type": "UInt8"}], "data": [{"a": 1}], "rows": 1}"#
        let server = ClickHouseStubServer { _ in
            ClickHouseStubReply(statusCode: 200, body: json, headers: ["X-ClickHouse-Format": "JSON"])
        }
        let driver = server.connectedDriver()

        let result = try #require(try await driver.executeBoundedQuery(query: "SELECT 1 AS a FORMAT JSON", rowCap: 100))

        #expect(result.columns.count == 1)
        #expect(result.rows == [[.text(json)]])
        #expect(!result.isTruncated)
    }

    @Test("An export of a query that names another format is refused, not cut or decoded as rows")
    func unboundedOtherFormatIsRefused() async throws {
        let server = ClickHouseStubServer { _ in
            ClickHouseStubReply(statusCode: 200, body: "1,2\n3,4\n", headers: ["X-ClickHouse-Format": "CSV"])
        }
        let driver = server.connectedDriver()

        await #expect(throws: ClickHouseError.self) {
            for try await _ in driver.streamRows(query: "SELECT 1, 2 FORMAT CSV") {}
        }
    }

    @Test("A tagged block in another format's body is the error")
    func taggedBlockInOtherFormat() async throws {
        let tag = "abkxtrlzqztxfthi"
        let message = "\(Self.throwIfMessage) (version 26.3.52.9 (official build))"
        let body = "1,0\n2,0\n\r\n__exception__\r\n\(tag)\r\n\(message)\n\(message.utf8.count + 1) \(tag)\r\n__exception__\r\n"
        let server = ClickHouseStubServer { _ in
            ClickHouseStubReply(
                statusCode: 200,
                body: body,
                headers: ["X-ClickHouse-Format": "CSV", "X-ClickHouse-Exception-Tag": tag]
            )
        }
        let driver = server.connectedDriver()

        await #expect(throws: ClickHouseError.self) {
            _ = try await driver.executeBoundedQuery(query: "SELECT 1 FORMAT CSV", rowCap: 100)
        }
    }

    @Test("A body in another format past the cap is cut and marked truncated")
    func otherFormatPastTheCap() async throws {
        let big = String(repeating: "x", count: 1_100_000)
        let server = ClickHouseStubServer { _ in
            ClickHouseStubReply(statusCode: 200, body: big, headers: ["X-ClickHouse-Format": "CSV"])
        }
        let driver = server.connectedDriver()

        let result = try #require(try await driver.executeBoundedQuery(query: "SELECT 1 FORMAT CSV", rowCap: 100))

        #expect(result.isTruncated)
    }

    /// With `send_progress_in_http_headers` the status goes out early, so a query that fails after
    /// the first progress header answers 200 and names the failure in a header.
    @Test("A 200 that carries X-ClickHouse-Exception-Code is a failure")
    func exceptionCodeHeaderOn200() async throws {
        let message = "\(Self.throwIfMessage) (version 23.8.8.20 (official build))"
        let server = ClickHouseStubServer { _ in
            ClickHouseStubReply(statusCode: 200, body: message + "\n", headers: ["X-ClickHouse-Exception-Code": "395"])
        }
        let driver = server.connectedDriver()

        do {
            _ = try await driver.execute(query: "SELECT throwIf(1)")
            Issue.record("expected a failure")
        } catch let error as ClickHouseError {
            #expect(error.message == message)
        }
    }
}
