import Foundation
@testable import TablePro
import XCTest

final class HttpRequestParserTests: XCTestCase {
    func testParsesSimpleGetRequest() throws {
        let raw = "GET /index HTTP/1.1\r\nHost: example.com\r\n\r\n"
        let result = try HttpRequestParser.parse(Data(raw.utf8))
        guard case .complete(let head, let body, let consumed) = result else {
            XCTFail("Expected complete, got \(result)")
            return
        }
        XCTAssertEqual(head.method, .get)
        XCTAssertEqual(head.path, "/index")
        XCTAssertEqual(head.httpVersion, "HTTP/1.1")
        XCTAssertEqual(head.headers.value(for: "Host"), "example.com")
        XCTAssertEqual(body, Data())
        XCTAssertEqual(consumed, raw.utf8.count)
    }

    func testCaseInsensitiveHeaderLookup() throws {
        let raw = "GET / HTTP/1.1\r\nContent-Type: text/plain\r\n\r\n"
        let result = try HttpRequestParser.parse(Data(raw.utf8))
        guard case .complete(let head, _, _) = result else {
            XCTFail("Expected complete")
            return
        }
        XCTAssertEqual(head.headers.value(for: "content-type"), "text/plain")
        XCTAssertEqual(head.headers.value(for: "CONTENT-TYPE"), "text/plain")
    }

    func testMcpSessionIdLookupCaseInsensitive() throws {
        let lowercaseRaw = "GET / HTTP/1.1\r\nmcp-session-id: abc-123\r\n\r\n"
        let lowercaseResult = try HttpRequestParser.parse(Data(lowercaseRaw.utf8))
        guard case .complete(let lowerHead, _, _) = lowercaseResult else {
            XCTFail("Expected complete for lowercase")
            return
        }
        XCTAssertEqual(lowerHead.headers.value(for: "Mcp-Session-Id"), "abc-123")

        let uppercaseRaw = "GET / HTTP/1.1\r\nMCP-SESSION-ID: xyz-789\r\n\r\n"
        let uppercaseResult = try HttpRequestParser.parse(Data(uppercaseRaw.utf8))
        guard case .complete(let upperHead, _, _) = uppercaseResult else {
            XCTFail("Expected complete for uppercase")
            return
        }
        XCTAssertEqual(upperHead.headers.value(for: "Mcp-Session-Id"), "xyz-789")
    }

    func testParsesPostBodyOfExactContentLength() throws {
        let body = "{\"x\":1}"
        let raw = "POST /rpc HTTP/1.1\r\nHost: x\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let result = try HttpRequestParser.parse(Data(raw.utf8))
        guard case .complete(let head, let parsedBody, let consumed) = result else {
            XCTFail("Expected complete")
            return
        }
        XCTAssertEqual(head.method, .post)
        XCTAssertEqual(parsedBody, Data(body.utf8))
        XCTAssertEqual(consumed, raw.utf8.count)
    }

    func testReportsExtraBytesAfterBodyViaConsumedBytes() throws {
        let body = "abc"
        let raw = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\n\(body)REMAINDER"
        let result = try HttpRequestParser.parse(Data(raw.utf8))
        guard case .complete(_, let parsedBody, let consumed) = result else {
            XCTFail("Expected complete")
            return
        }
        XCTAssertEqual(parsedBody, Data(body.utf8))
        let expectedConsumed = raw.utf8.count - "REMAINDER".utf8.count
        XCTAssertEqual(consumed, expectedConsumed)
    }

    func testIncompleteWhenHeadersNotFinished() throws {
        let raw = "GET / HTTP/1.1\r\nHost: x"
        let result = try HttpRequestParser.parse(Data(raw.utf8))
        XCTAssertEqual(result, .incomplete)
    }

    func testIncompleteWhenBodyShorterThanContentLength() throws {
        let raw = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\nshort"
        let result = try HttpRequestParser.parse(Data(raw.utf8))
        XCTAssertEqual(result, .incomplete)
    }

    func testRejectsBareLfAsTerminator() {
        let raw = "GET / HTTP/1.1\nHost: x\n\n"
        XCTAssertThrowsError(try HttpRequestParser.parse(Data(raw.utf8))) { error in
            XCTAssertEqual(error as? HttpRequestParseError, .nonStrictLineEndings)
        }
    }

    func testRejectsBareLfInHeaderLine() {
        let raw = "GET / HTTP/1.1\r\nBad: value\nHost: x\r\n\r\n"
        XCTAssertThrowsError(try HttpRequestParser.parse(Data(raw.utf8))) { error in
            XCTAssertEqual(error as? HttpRequestParseError, .nonStrictLineEndings)
        }
    }

    func testRejectsHeaderTooLarge() {
        let bigHeaderValue = String(repeating: "a", count: 17 * 1_024)
        let raw = "GET / HTTP/1.1\r\nX-Big: \(bigHeaderValue)\r\n\r\n"
        XCTAssertThrowsError(try HttpRequestParser.parse(Data(raw.utf8))) { error in
            XCTAssertEqual(error as? HttpRequestParseError, .headerTooLarge)
        }
    }

    func testRejectsHeaderTooLargeWithoutTerminator() {
        let huge = String(repeating: "X-Pad: pad\r\n", count: 2_000)
        let raw = "GET / HTTP/1.1\r\n\(huge)"
        XCTAssertThrowsError(try HttpRequestParser.parse(Data(raw.utf8))) { error in
            XCTAssertEqual(error as? HttpRequestParseError, .headerTooLarge)
        }
    }

    func testUnknownMethodMappedToOther() throws {
        let raw = "PROPFIND / HTTP/1.1\r\nHost: x\r\n\r\n"
        let result = try HttpRequestParser.parse(Data(raw.utf8))
        guard case .complete(let head, _, _) = result else {
            XCTFail("Expected complete")
            return
        }
        XCTAssertEqual(head.method, .other("PROPFIND"))
    }

    func testRejectsBodyOverLimit() {
        let raw = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 99999999\r\n\r\n"
        XCTAssertThrowsError(try HttpRequestParser.parse(Data(raw.utf8))) { error in
            guard case HttpRequestParseError.bodyTooLarge = error else {
                XCTFail("Expected bodyTooLarge")
                return
            }
        }
    }

    func testPathPreservedVerbatim() throws {
        let raw = "GET /path%20with%20spaces?x=1 HTTP/1.1\r\nHost: x\r\n\r\n"
        let result = try HttpRequestParser.parse(Data(raw.utf8))
        guard case .complete(let head, _, _) = result else {
            XCTFail("Expected complete")
            return
        }
        XCTAssertEqual(head.path, "/path%20with%20spaces?x=1")
    }
}
