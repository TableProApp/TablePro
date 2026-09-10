import Foundation
import TableProPluginKit
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
        let raw = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: text/plain\r\n\r\n"
        let result = try HttpRequestParser.parse(Data(raw.utf8))
        guard case .complete(let head, _, _) = result else {
            XCTFail("Expected complete")
            return
        }
        XCTAssertEqual(head.headers.value(for: "content-type"), "text/plain")
        XCTAssertEqual(head.headers.value(for: "CONTENT-TYPE"), "text/plain")
    }

    func testMcpRequestMetadataHeaderLookupIsCaseInsensitive() throws {
        let raw = "POST /mcp HTTP/1.1\r\nHost: x\r\nmcp-protocol-version: 2026-07-28\r\nMCP-METHOD: tools/call\r\n"
            + "mcp-name: run_query\r\n\r\n"
        let result = try HttpRequestParser.parse(Data(raw.utf8))
        guard case .complete(let head, _, _) = result else {
            XCTFail("Expected complete")
            return
        }
        XCTAssertEqual(head.headers.value(for: MCPHttpHeaderValidator.protocolVersionHeader), "2026-07-28")
        XCTAssertEqual(head.headers.value(for: MCPHttpHeaderValidator.methodHeader), "tools/call")
        XCTAssertEqual(head.headers.value(for: MCPHttpHeaderValidator.nameHeader), "run_query")
    }

    func testParameterHeaderPrefixMatchIsCaseInsensitive() throws {
        let raw = "POST /mcp HTTP/1.1\r\nHost: x\r\nmcp-param-Region: us-west1\r\nMcp-Param-Limit: 42\r\n\r\n"
        let result = try HttpRequestParser.parse(Data(raw.utf8))
        guard case .complete(let head, _, _) = result else {
            XCTFail("Expected complete")
            return
        }
        let pairs = head.headers.pairs(withPrefix: MCPHttpHeaderValidator.parameterHeaderPrefix)
        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(pairs.map(\.1).sorted(), ["42", "us-west1"])
    }

    func testHeaderValuesKeepTheirCase() throws {
        let raw = "POST /mcp HTTP/1.1\r\nHost: x\r\nMcp-Name: RunQuery\r\n\r\n"
        let result = try HttpRequestParser.parse(Data(raw.utf8))
        guard case .complete(let head, _, _) = result else {
            XCTFail("Expected complete")
            return
        }
        XCTAssertEqual(head.headers.value(for: "mcp-name"), "RunQuery")
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

    func testDecodesAChunkedBodyRatherThanReadingItAsEmpty() throws {
        let raw = "POST /mcp HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "4\r\n{\"a\"\r\n4\r\n:1}\n\r\n0\r\n\r\n"
        let result = try HttpRequestParser.parse(Data(raw.utf8))
        guard case .complete(_, let body, _) = result else {
            XCTFail("Expected complete")
            return
        }
        XCTAssertEqual(String(data: body, encoding: .utf8), "{\"a\":1}\n")
        XCTAssertFalse(body.isEmpty)
    }

    func testRejectsChunkedTogetherWithContentLength() {
        let raw = "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nContent-Length: 3\r\n\r\n0\r\n\r\n"
        XCTAssertThrowsError(try HttpRequestParser.parse(Data(raw.utf8))) { error in
            XCTAssertEqual(error as? HttpRequestParseError, .malformedHeader)
        }
    }

    func testRejectsUnsupportedTransferCoding() {
        let raw = "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip\r\n\r\n"
        XCTAssertThrowsError(try HttpRequestParser.parse(Data(raw.utf8))) { error in
            XCTAssertEqual(error as? HttpRequestParseError, .unsupportedTransferEncoding("gzip"))
        }
    }

    func testDeclaredContentLengthIsCheckedBeforeAnyBodyByteArrives() {
        let limits = HttpParserLimits(maxHeaderBytes: 1_024, maxBodyBytes: 16)
        let raw = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 4096\r\n\r\n"
        XCTAssertThrowsError(try HttpRequestParser.parse(Data(raw.utf8), limits: limits)) { error in
            XCTAssertEqual(error as? HttpRequestParseError, .bodyTooLarge(limit: 16, actual: 4_096))
        }
    }

    func testRejectsNegativeAndNonNumericContentLength() {
        for value in ["-1", "abc", "1 2"] {
            let raw = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: \(value)\r\n\r\n"
            XCTAssertThrowsError(try HttpRequestParser.parse(Data(raw.utf8)), "Content-Length: \(value)") { error in
                XCTAssertEqual(error as? HttpRequestParseError, .malformedHeader)
            }
        }
    }

    func testRejectsAHeaderNameWithWhitespaceBeforeTheColon() {
        let raw = "GET / HTTP/1.1\r\nHost: x\r\nX-Bad : value\r\n\r\n"
        XCTAssertThrowsError(try HttpRequestParser.parse(Data(raw.utf8))) { error in
            XCTAssertEqual(error as? HttpRequestParseError, .malformedHeader)
        }
    }

    func testRejectsAnUnknownHttpVersionToken() {
        let raw = "GET / RTSP/1.0\r\nHost: x\r\n\r\n"
        XCTAssertThrowsError(try HttpRequestParser.parse(Data(raw.utf8))) { error in
            XCTAssertEqual(error as? HttpRequestParseError, .unsupportedHttpVersion("RTSP/1.0"))
        }
    }

    func testHttpTenNeedsNoHostHeader() throws {
        let raw = "GET /mcp HTTP/1.0\r\n\r\n"
        let result = try HttpRequestParser.parse(Data(raw.utf8))
        guard case .complete(let head, _, _) = result else {
            XCTFail("Expected complete")
            return
        }
        XCTAssertEqual(head.httpVersion, "HTTP/1.0")
        XCTAssertFalse(head.wantsKeepAlive)
    }

    func testKeepAliveDefaultsOnForHttpElevenAndOffForConnectionClose() throws {
        let keepAlive = "GET / HTTP/1.1\r\nHost: x\r\n\r\n"
        let closing = "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
        guard case .complete(let keepHead, _, _) = try HttpRequestParser.parse(Data(keepAlive.utf8)),
              case .complete(let closeHead, _, _) = try HttpRequestParser.parse(Data(closing.utf8)) else {
            XCTFail("Expected complete")
            return
        }
        XCTAssertTrue(keepHead.wantsKeepAlive)
        XCTAssertFalse(closeHead.wantsKeepAlive)
    }

    func testPathWithoutQueryStripsTheQueryString() throws {
        let raw = "POST /mcp?debug=1 HTTP/1.1\r\nHost: x\r\n\r\n"
        guard case .complete(let head, _, _) = try HttpRequestParser.parse(Data(raw.utf8)) else {
            XCTFail("Expected complete")
            return
        }
        XCTAssertEqual(head.path, "/mcp?debug=1")
        XCTAssertEqual(head.pathWithoutQuery, "/mcp")
    }
}
