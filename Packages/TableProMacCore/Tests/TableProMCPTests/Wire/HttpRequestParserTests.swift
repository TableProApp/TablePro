import Foundation
@testable import TableProMCP
import Testing

struct HttpRequestParserTests {
    @Test func testParsesSimpleGetRequest() throws {
        let raw = "GET /index HTTP/1.1\r\nHost: example.com\r\n\r\n"
        let result = try HttpRequestParser.parse(Data(raw.utf8))
        guard case .complete(let head, let body, let consumed) = result else {
            Issue.record("Expected complete, got \(result)")
            return
        }
        #expect(head.method == .get)
        #expect(head.path == "/index")
        #expect(head.httpVersion == "HTTP/1.1")
        #expect(head.headers.value(for: "Host") == "example.com")
        #expect(body == Data())
        #expect(consumed == raw.utf8.count)
    }

    @Test func testCaseInsensitiveHeaderLookup() throws {
        let raw = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: text/plain\r\n\r\n"
        let result = try HttpRequestParser.parse(Data(raw.utf8))
        guard case .complete(let head, _, _) = result else {
            Issue.record("Expected complete")
            return
        }
        #expect(head.headers.value(for: "content-type") == "text/plain")
        #expect(head.headers.value(for: "CONTENT-TYPE") == "text/plain")
    }

    @Test func testMcpRequestMetadataHeaderLookupIsCaseInsensitive() throws {
        let raw = "POST /mcp HTTP/1.1\r\nHost: x\r\nmcp-protocol-version: 2026-07-28\r\nMCP-METHOD: tools/call\r\n"
            + "mcp-name: run_query\r\n\r\n"
        let result = try HttpRequestParser.parse(Data(raw.utf8))
        guard case .complete(let head, _, _) = result else {
            Issue.record("Expected complete")
            return
        }
        #expect(head.headers.value(for: MCPHttpHeaderValidator.protocolVersionHeader) == "2026-07-28")
        #expect(head.headers.value(for: MCPHttpHeaderValidator.methodHeader) == "tools/call")
        #expect(head.headers.value(for: MCPHttpHeaderValidator.nameHeader) == "run_query")
    }

    @Test func testParameterHeaderPrefixMatchIsCaseInsensitive() throws {
        let raw = "POST /mcp HTTP/1.1\r\nHost: x\r\nmcp-param-Region: us-west1\r\nMcp-Param-Limit: 42\r\n\r\n"
        let result = try HttpRequestParser.parse(Data(raw.utf8))
        guard case .complete(let head, _, _) = result else {
            Issue.record("Expected complete")
            return
        }
        let pairs = head.headers.pairs(withPrefix: MCPHttpHeaderValidator.parameterHeaderPrefix)
        #expect(pairs.count == 2)
        #expect(pairs.map(\.1).sorted() == ["42", "us-west1"])
    }

    @Test func testHeaderValuesKeepTheirCase() throws {
        let raw = "POST /mcp HTTP/1.1\r\nHost: x\r\nMcp-Name: RunQuery\r\n\r\n"
        let result = try HttpRequestParser.parse(Data(raw.utf8))
        guard case .complete(let head, _, _) = result else {
            Issue.record("Expected complete")
            return
        }
        #expect(head.headers.value(for: "mcp-name") == "RunQuery")
    }

    @Test func testParsesPostBodyOfExactContentLength() throws {
        let body = "{\"x\":1}"
        let raw = "POST /rpc HTTP/1.1\r\nHost: x\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let result = try HttpRequestParser.parse(Data(raw.utf8))
        guard case .complete(let head, let parsedBody, let consumed) = result else {
            Issue.record("Expected complete")
            return
        }
        #expect(head.method == .post)
        #expect(parsedBody == Data(body.utf8))
        #expect(consumed == raw.utf8.count)
    }

    @Test func testReportsExtraBytesAfterBodyViaConsumedBytes() throws {
        let body = "abc"
        let raw = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\n\(body)REMAINDER"
        let result = try HttpRequestParser.parse(Data(raw.utf8))
        guard case .complete(_, let parsedBody, let consumed) = result else {
            Issue.record("Expected complete")
            return
        }
        #expect(parsedBody == Data(body.utf8))
        let expectedConsumed = raw.utf8.count - "REMAINDER".utf8.count
        #expect(consumed == expectedConsumed)
    }

    @Test("Unfinished headers, or a body shorter than Content-Length, is incomplete", arguments: [
        "GET / HTTP/1.1\r\nHost: x",
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\nshort",
    ])
    func testIncompleteRequest(_ raw: String) throws {
        let result = try HttpRequestParser.parse(Data(raw.utf8))
        #expect(result == .incomplete)
    }

    @Test("A bare LF as the terminator or inside a header line is rejected", arguments: [
        "GET / HTTP/1.1\nHost: x\n\n",
        "GET / HTTP/1.1\r\nBad: value\nHost: x\r\n\r\n",
    ])
    func testRejectsBareLf(_ raw: String) {
        if let error = #expect(throws: (any Error).self, performing: { try HttpRequestParser.parse(Data(raw.utf8)) }) {
            #expect(error as? HttpRequestParseError == .nonStrictLineEndings)
        }
    }

    @Test func testRejectsHeaderTooLarge() {
        let bigHeaderValue = String(repeating: "a", count: 17 * 1_024)
        let raw = "GET / HTTP/1.1\r\nX-Big: \(bigHeaderValue)\r\n\r\n"
        if let error = #expect(throws: (any Error).self, performing: { try HttpRequestParser.parse(Data(raw.utf8)) }) {
            #expect(error as? HttpRequestParseError == .headerTooLarge)
        }
    }

    @Test func testRejectsHeaderTooLargeWithoutTerminator() {
        let huge = String(repeating: "X-Pad: pad\r\n", count: 2_000)
        let raw = "GET / HTTP/1.1\r\n\(huge)"
        if let error = #expect(throws: (any Error).self, performing: { try HttpRequestParser.parse(Data(raw.utf8)) }) {
            #expect(error as? HttpRequestParseError == .headerTooLarge)
        }
    }

    @Test func testUnknownMethodMappedToOther() throws {
        let raw = "PROPFIND / HTTP/1.1\r\nHost: x\r\n\r\n"
        let result = try HttpRequestParser.parse(Data(raw.utf8))
        guard case .complete(let head, _, _) = result else {
            Issue.record("Expected complete")
            return
        }
        #expect(head.method == .other("PROPFIND"))
    }

    @Test func testRejectsBodyOverLimit() {
        let raw = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 99999999\r\n\r\n"
        if let error = #expect(throws: (any Error).self, performing: { try HttpRequestParser.parse(Data(raw.utf8)) }) {
            guard case HttpRequestParseError.bodyTooLarge = error else {
                Issue.record("Expected bodyTooLarge")
                return
            }
        }
    }

    @Test func testPathPreservedVerbatim() throws {
        let raw = "GET /path%20with%20spaces?x=1 HTTP/1.1\r\nHost: x\r\n\r\n"
        let result = try HttpRequestParser.parse(Data(raw.utf8))
        guard case .complete(let head, _, _) = result else {
            Issue.record("Expected complete")
            return
        }
        #expect(head.path == "/path%20with%20spaces?x=1")
    }

    @Test func testDecodesAChunkedBodyRatherThanReadingItAsEmpty() throws {
        let raw = "POST /mcp HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "4\r\n{\"a\"\r\n4\r\n:1}\n\r\n0\r\n\r\n"
        let result = try HttpRequestParser.parse(Data(raw.utf8))
        guard case .complete(_, let body, _) = result else {
            Issue.record("Expected complete")
            return
        }
        #expect(String(data: body, encoding: .utf8) == "{\"a\":1}\n")
        #expect(!body.isEmpty)
    }

    @Test("Chunked together with Content-Length, or whitespace before a header colon, is a malformed header", arguments: [
        "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nContent-Length: 3\r\n\r\n0\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: x\r\nX-Bad : value\r\n\r\n",
    ])
    func testRejectsMalformedHeader(_ raw: String) {
        if let error = #expect(throws: (any Error).self, performing: { try HttpRequestParser.parse(Data(raw.utf8)) }) {
            #expect(error as? HttpRequestParseError == .malformedHeader)
        }
    }

    @Test func testRejectsUnsupportedTransferCoding() {
        let raw = "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip\r\n\r\n"
        if let error = #expect(throws: (any Error).self, performing: { try HttpRequestParser.parse(Data(raw.utf8)) }) {
            #expect(error as? HttpRequestParseError == .unsupportedTransferEncoding("gzip"))
        }
    }

    @Test func testDeclaredContentLengthIsCheckedBeforeAnyBodyByteArrives() {
        let limits = HttpParserLimits(maxHeaderBytes: 1_024, maxBodyBytes: 16)
        let raw = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 4096\r\n\r\n"
        if let error = #expect(throws: (any Error).self, performing: { try HttpRequestParser.parse(Data(raw.utf8), limits: limits) }) {
            #expect(error as? HttpRequestParseError == .bodyTooLarge(limit: 16, actual: 4_096))
        }
    }

    @Test func testRejectsNegativeAndNonNumericContentLength() {
        for value in ["-1", "abc", "1 2"] {
            let raw = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: \(value)\r\n\r\n"
            if let error = #expect(throws: (any Error).self, "Content-Length: \(value)", performing: { try HttpRequestParser.parse(Data(raw.utf8)) }) {
                #expect(error as? HttpRequestParseError == .malformedHeader)
            }
        }
    }

    @Test func testRejectsAnUnknownHttpVersionToken() {
        let raw = "GET / RTSP/1.0\r\nHost: x\r\n\r\n"
        if let error = #expect(throws: (any Error).self, performing: { try HttpRequestParser.parse(Data(raw.utf8)) }) {
            #expect(error as? HttpRequestParseError == .unsupportedHttpVersion("RTSP/1.0"))
        }
    }

    @Test func testHttpTenNeedsNoHostHeader() throws {
        let raw = "GET /mcp HTTP/1.0\r\n\r\n"
        let result = try HttpRequestParser.parse(Data(raw.utf8))
        guard case .complete(let head, _, _) = result else {
            Issue.record("Expected complete")
            return
        }
        #expect(head.httpVersion == "HTTP/1.0")
        #expect(!head.wantsKeepAlive)
    }

    @Test func testKeepAliveDefaultsOnForHttpElevenAndOffForConnectionClose() throws {
        let keepAlive = "GET / HTTP/1.1\r\nHost: x\r\n\r\n"
        let closing = "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
        guard case .complete(let keepHead, _, _) = try HttpRequestParser.parse(Data(keepAlive.utf8)),
              case .complete(let closeHead, _, _) = try HttpRequestParser.parse(Data(closing.utf8)) else {
            Issue.record("Expected complete")
            return
        }
        #expect(keepHead.wantsKeepAlive)
        #expect(!closeHead.wantsKeepAlive)
    }

    @Test func testPathWithoutQueryStripsTheQueryString() throws {
        let raw = "POST /mcp?debug=1 HTTP/1.1\r\nHost: x\r\n\r\n"
        guard case .complete(let head, _, _) = try HttpRequestParser.parse(Data(raw.utf8)) else {
            Issue.record("Expected complete")
            return
        }
        #expect(head.path == "/mcp?debug=1")
        #expect(head.pathWithoutQuery == "/mcp")
    }
}
