import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("MCP HTTP Keep-Alive", .serialized)
struct MCPHttpKeepAliveTests {
    private func shortIdleLimits(_ timeout: Duration) -> MCPHttpServerLimits {
        MCPHttpServerLimits(
            maxRequestBodyBytes: 1_024 * 1_024,
            maxHeaderBytes: 16 * 1_024,
            connectionTimeout: timeout
        )
    }

    @Test("Two requests on one connection both get an answer")
    func twoRequestsOnOneConnection() async throws {
        try await MCPTransportTestHarness.withServer(limits: shortIdleLimits(.seconds(10))) { port in
            let client = RawHttpTestClient(port: port)
            try await client.connect()
            defer { Task { await client.close() } }

            try await client.send(
                try MCPTransportTestRequests.modernPost(port: port, id: 1, method: "tools/list")
            )
            let first = try await client.readResponse()
            #expect(first.statusCode == 200)
            #expect(first.header("Connection") == "keep-alive")

            try await client.send(
                try MCPTransportTestRequests.modernPost(port: port, id: 2, method: "tools/call", name: "list_tables")
            )
            let second = try await client.readResponse()
            #expect(second.statusCode == 200)
            #expect(try second.jsonRpcResult()["method"]?.stringValue == "tools/call")
            #expect(await client.isPeerClosed() == false)
        }
    }

    @Test("Pipelined requests are drained from the buffer without a second write")
    func pipelinedRequestsAreDrained() async throws {
        try await MCPTransportTestHarness.withServer(limits: shortIdleLimits(.seconds(10))) { port in
            let client = RawHttpTestClient(port: port)
            try await client.connect()
            defer { Task { await client.close() } }

            var batch = try MCPTransportTestRequests.modernPost(port: port, id: 1, method: "tools/list")
            batch.append(
                try MCPTransportTestRequests.modernPost(port: port, id: 2, method: "tools/call", name: "list_tables")
            )
            try await client.send(batch)

            let first = try await client.readResponse()
            let second = try await client.readResponse()
            #expect(first.statusCode == 200)
            #expect(second.statusCode == 200)
            #expect(try first.jsonRpcResult()["method"]?.stringValue == "tools/list")
            #expect(try second.jsonRpcResult()["method"]?.stringValue == "tools/call")

            try await client.send(
                try MCPTransportTestRequests.modernPost(port: port, id: 3, method: "tools/list")
            )
            let third = try await client.readResponse()
            #expect(third.statusCode == 200)
        }
    }

    @Test("Connection: close ends the connection after the response")
    func connectionCloseEndsTheConnection() async throws {
        try await MCPTransportTestHarness.withServer(limits: shortIdleLimits(.seconds(10))) { port in
            let client = RawHttpTestClient(port: port)
            try await client.connect()
            defer { Task { await client.close() } }

            try await client.send(
                try MCPTransportTestRequests.modernPost(
                    port: port,
                    id: 1,
                    method: "tools/list",
                    extraHeaders: [("Connection", "close")]
                )
            )
            let response = try await client.readResponse()
            #expect(response.statusCode == 200)
            #expect(response.header("Connection") == "close")
            #expect(await client.waitForClose(timeout: .seconds(3)))
        }
    }

    @Test("An idle connection is closed by the idle timeout rather than pinned forever")
    func idleConnectionIsClosed() async throws {
        try await MCPTransportTestHarness.withServer(limits: shortIdleLimits(.milliseconds(300))) { port in
            let client = RawHttpTestClient(port: port)
            try await client.connect()
            defer { Task { await client.close() } }

            #expect(await client.waitForClose(timeout: .seconds(5)), "a silent connection must not be held open")
        }
    }

    @Test("A connection idles out after a completed request too")
    func idleAfterResponse() async throws {
        try await MCPTransportTestHarness.withServer(limits: shortIdleLimits(.milliseconds(500))) { port in
            let client = RawHttpTestClient(port: port)
            try await client.connect()
            defer { Task { await client.close() } }

            try await client.send(
                try MCPTransportTestRequests.modernPost(port: port, id: 1, method: "tools/list")
            )
            let response = try await client.readResponse()
            #expect(response.statusCode == 200)
            #expect(await client.waitForClose(timeout: .seconds(5)))
        }
    }

    @Test("A half-sent request answers 408 when the idle timeout fires")
    func partialRequestTimesOut() async throws {
        try await MCPTransportTestHarness.withServer(limits: shortIdleLimits(.milliseconds(800))) { port in
            let client = RawHttpTestClient(port: port)
            try await client.connect()
            defer { Task { await client.close() } }

            let head = MCPTransportTestRequests.raw(
                port: port,
                headers: MCPTransportTestRequests.standardHeaders(method: "tools/list"),
                body: nil,
                includeContentLength: false,
                completeHead: false
            )
            try await client.send(head)

            let response = try await client.readResponse(timeout: .seconds(5))
            #expect(response.statusCode == 408)
            #expect(response.header("Content-Length") == "0")
            #expect(await client.waitForClose(timeout: .seconds(3)))
        }
    }

    @Test("The SSE keep-alive is a bare colon comment line")
    func sseKeepAliveCommentShape() async {
        let recorder = TransportTestRecorder()
        let writer = MCPSseWriter(
            emit: { data in await recorder.append(data) },
            isAlive: { true }
        )
        await writer.writeComment("")
        await writer.stop()

        #expect(await recorder.text() == ":\r\n")
    }

    @Test("An SSE keep-alive comment carries no event data for the decoder")
    func sseKeepAliveIsIgnoredByDecoder() async {
        let decoder = SseDecoder()
        let frames = await decoder.feed(Data(":\r\n".utf8))

        #expect(frames.isEmpty)
    }

    @Test("The SSE keep-alive interval is short enough to hold a proxy connection open")
    func sseKeepAliveIntervalIsBounded() {
        #expect(MCPSseWriter.keepAliveInterval > .zero)
        #expect(MCPSseWriter.keepAliveInterval <= .seconds(30))
    }

    @Test("A stopped SSE writer emits nothing more")
    func stoppedWriterIsSilent() async {
        let recorder = TransportTestRecorder()
        let writer = MCPSseWriter(
            emit: { data in await recorder.append(data) },
            isAlive: { true }
        )
        await writer.stop()
        await writer.writeComment("late")
        await writer.writeFrame(SseFrame(data: "late"))

        #expect(await recorder.count() == 0)
    }
}
