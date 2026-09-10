import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("HTTP Request Stream Parser")
struct HttpRequestStreamParserTests {
    private func drain(_ parser: inout HttpRequestStreamParser) throws -> [HttpParsedRequest] {
        var requests: [HttpParsedRequest] = []
        while let request = try parser.next() {
            requests.append(request)
        }
        return requests
    }

    @Test("Byte-at-a-time feeding parses pipelined requests in order")
    func pipelinedByteAtATime() throws {
        let raw = "POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nabcde"
            + "POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\nzz"
        var parser = HttpRequestStreamParser()
        var bodies: [String] = []
        for byte in Array(raw.utf8) {
            parser.append(Data([byte]))
            for request in try drain(&parser) {
                bodies.append(String(bytes: request.body, encoding: .utf8) ?? "")
            }
        }
        #expect(bodies == ["abcde", "zz"])
        #expect(parser.pendingByteCount == 0)
    }

    @Test("Chunked bodies are decoded, not treated as empty")
    func chunkedBodies() throws {
        let raw = "POST /mcp HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
        var parser = HttpRequestStreamParser()
        parser.append(Data(raw.utf8))
        let requests = try drain(&parser)
        #expect(requests.count == 1)
        #expect(String(bytes: requests[0].body, encoding: .utf8) == "hello world")
        #expect(parser.pendingByteCount == 0)
    }

    @Test("Chunked bodies honour the body cap")
    func chunkedBodyCap() {
        let raw = "POST /mcp HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n9\r\n123456789\r\n0\r\n\r\n"
        var parser = HttpRequestStreamParser(limits: HttpParserLimits(maxHeaderBytes: 128, maxBodyBytes: 8))
        parser.append(Data(raw.utf8))
        #expect(throws: HttpRequestParseError.self) {
            _ = try parser.next()
        }
    }

    @Test("Unsupported transfer codings are rejected instead of silently dropped")
    func unsupportedTransferEncoding() {
        var parser = HttpRequestStreamParser()
        parser.append(Data("POST /mcp HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip\r\n\r\n".utf8))
        do {
            _ = try parser.next()
            Issue.record("Expected unsupportedTransferEncoding")
        } catch {
            #expect(error as? HttpRequestParseError == .unsupportedTransferEncoding("gzip"))
        }
    }

    @Test("HTTP/1.1 requests without a Host header are rejected")
    func missingHostHeader() {
        var parser = HttpRequestStreamParser()
        parser.append(Data("GET /mcp HTTP/1.1\r\nAccept: */*\r\n\r\n".utf8))
        do {
            _ = try parser.next()
            Issue.record("Expected missingHostHeader")
        } catch {
            #expect(error as? HttpRequestParseError == .missingHostHeader)
        }
    }

    @Test("Duplicate Host and Content-Length headers are rejected")
    func duplicateFramingHeaders() {
        var duplicateHost = HttpRequestStreamParser()
        duplicateHost.append(Data("GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n".utf8))
        #expect(throws: HttpRequestParseError.self) {
            _ = try duplicateHost.next()
        }

        var duplicateLength = HttpRequestStreamParser()
        duplicateLength.append(
            Data("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nab".utf8)
        )
        #expect(throws: HttpRequestParseError.self) {
            _ = try duplicateLength.next()
        }
    }

    @Test("A leading empty line before the request line is ignored")
    func leadingEmptyLine() throws {
        var parser = HttpRequestStreamParser()
        parser.append(Data("\r\nGET /mcp HTTP/1.1\r\nHost: x\r\n\r\n".utf8))
        let requests = try drain(&parser)
        #expect(requests.count == 1)
        #expect(requests[0].head.path == "/mcp")
    }

    @Test("Chunk extensions and trailer fields are tolerated")
    func chunkExtensionsAndTrailers() throws {
        let raw = "POST /mcp HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "5;name=value\r\nhello\r\n0\r\nX-Trailer: 1\r\n\r\n"
        var parser = HttpRequestStreamParser()
        parser.append(Data(raw.utf8))
        let requests = try drain(&parser)
        #expect(requests.count == 1)
        #expect(String(bytes: requests[0].body, encoding: .utf8) == "hello")
    }

    @Test("A chunked request is followed by a pipelined request on the same buffer")
    func chunkedThenPipelined() throws {
        let raw = "POST /mcp HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nhi\r\n0\r\n\r\n"
            + "POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nbye"
        var parser = HttpRequestStreamParser()
        parser.append(Data(raw.utf8))
        let requests = try drain(&parser)
        #expect(requests.count == 2)
        #expect(String(bytes: requests[0].body, encoding: .utf8) == "hi")
        #expect(String(bytes: requests[1].body, encoding: .utf8) == "bye")
        #expect(parser.pendingByteCount == 0)
    }

    @Test("A chunked body arriving one byte at a time still decodes")
    func chunkedByteAtATime() throws {
        let raw = "POST /mcp HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "3\r\nabc\r\n3\r\ndef\r\n0\r\n\r\n"
        var parser = HttpRequestStreamParser()
        var bodies: [String] = []
        for byte in Array(raw.utf8) {
            parser.append(Data([byte]))
            for request in try drain(&parser) {
                bodies.append(String(bytes: request.body, encoding: .utf8) ?? "")
            }
        }
        #expect(bodies == ["abcdef"])
    }

    @Test("A malformed chunk size is rejected")
    func malformedChunkSize() {
        var parser = HttpRequestStreamParser()
        parser.append(
            Data("POST /mcp HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n".utf8)
        )
        #expect(throws: HttpRequestParseError.self) {
            _ = try parser.next()
        }
    }

    @Test("A chunk that is not terminated by CRLF is rejected")
    func malformedChunkTerminator() {
        var parser = HttpRequestStreamParser()
        parser.append(
            Data("POST /mcp HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nhiXX".utf8)
        )
        #expect(throws: HttpRequestParseError.self) {
            _ = try parser.next()
        }
    }

    @Test("The parser reports whether it sits between requests")
    func betweenRequestsTracking() throws {
        var parser = HttpRequestStreamParser()
        #expect(parser.isBetweenRequests)

        parser.append(Data("POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nab".utf8))
        let partial = try parser.next()
        #expect(partial == nil)
        #expect(!parser.isBetweenRequests, "a half-read request is not an idle connection")

        parser.append(Data("cde".utf8))
        let completed = try parser.next()
        #expect(completed != nil)
        #expect(parser.isBetweenRequests)
        #expect(parser.pendingByteCount == 0)
    }

    @Test("A head split across chunk boundaries is parsed once it completes")
    func headSplitAcrossChunks() throws {
        var parser = HttpRequestStreamParser()
        parser.append(Data("POST /mcp HTTP/1.1\r\nHost: ".utf8))
        let afterRequestLine = try parser.next()
        #expect(afterRequestLine == nil)
        parser.append(Data("x\r\nContent-Length: 2\r\n".utf8))
        let afterHeaders = try parser.next()
        #expect(afterHeaders == nil)
        parser.append(Data("\r\nok".utf8))
        let request = try parser.next()
        #expect(request?.head.pathWithoutQuery == "/mcp")
        #expect(String(bytes: request?.body ?? Data(), encoding: .utf8) == "ok")
    }

    @Test("A request with no body is followed immediately by the next request")
    func bodylessPipelining() throws {
        let raw = "GET /mcp HTTP/1.1\r\nHost: x\r\n\r\nGET /mcp HTTP/1.1\r\nHost: x\r\n\r\n"
        var parser = HttpRequestStreamParser()
        parser.append(Data(raw.utf8))
        let requests = try drain(&parser)
        #expect(requests.count == 2)
        #expect(parser.pendingByteCount == 0)
    }
}
