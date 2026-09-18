import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("MCP HTTP Server Transport", .serialized)
struct MCPHttpServerTransportTests {
    private func exchange(port: UInt16, request: Data) async throws -> RawHttpTestResponse {
        let client = RawHttpTestClient(port: port)
        try await client.connect()
        defer { Task { await client.close() } }
        try await client.send(request)
        return try await client.readResponse()
    }

    @Test("A modern POST answers with a single JSON object and no session header")
    func modernPostAnswersJson() async throws {
        try await MCPTransportTestHarness.withServer { port in
            let request = try MCPTransportTestRequests.modernPost(port: port, id: 1, method: "tools/list")
            let response = try await exchange(port: port, request: request)

            #expect(response.statusCode == 200)
            #expect(response.header("Content-Type") == "application/json")
            #expect(!response.hasHeader("Mcp-Session-Id"))
            let result = try response.jsonRpcResult()
            #expect(result["method"]?.stringValue == "tools/list")
            #expect(result["protocolVersion"]?.stringValue == MCPProtocolVersion.latest.rawValue)
        }
    }

    @Test("GET and DELETE on the MCP endpoint answer 405 with an Allow header")
    func getAndDeleteAreMethodNotAllowed() async throws {
        try await MCPTransportTestHarness.withServer { port in
            for method in ["GET", "DELETE"] {
                let request = MCPTransportTestRequests.raw(
                    method: method,
                    port: port,
                    headers: [("Authorization", MCPTransportTestRequests.bearerToken)],
                    body: nil,
                    includeContentLength: false
                )
                let response = try await exchange(port: port, request: request)
                #expect(response.statusCode == 405, "\(method) /mcp must be 405")
                let allow = response.header("Allow")
                #expect(allow?.contains("POST") == true, "\(method) /mcp must advertise POST")
                #expect(allow?.contains("OPTIONS") == true, "\(method) /mcp must advertise OPTIONS")
                #expect(allow?.contains("GET") == false, "the GET stream endpoint is gone in 2026-07-28")
            }
        }
    }

    @Test("An inbound Mcp-Session-Id is ignored and never echoed back")
    func sessionHeaderIsIgnored() async throws {
        try await MCPTransportTestHarness.withServer { port in
            let request = try MCPTransportTestRequests.modernPost(
                port: port,
                id: 2,
                method: "tools/list",
                extraHeaders: [("Mcp-Session-Id", "a-session-from-an-older-client")]
            )
            let response = try await exchange(port: port, request: request)

            #expect(response.statusCode == 200)
            #expect(!response.hasHeader("Mcp-Session-Id"))
        }
    }

    @Test("A Last-Event-ID header is ignored rather than refused")
    func lastEventIdIsIgnored() async throws {
        try await MCPTransportTestHarness.withServer { port in
            let request = try MCPTransportTestRequests.modernPost(
                port: port,
                id: 3,
                method: "tools/list",
                extraHeaders: [("Last-Event-ID", "17")]
            )
            let response = try await exchange(port: port, request: request)

            #expect(response.statusCode == 200)
        }
    }

    @Test("A missing MCP-Protocol-Version header is -32020 with HTTP 400")
    func missingProtocolVersionHeader() async throws {
        try await MCPTransportTestHarness.withServer { port in
            let body = try MCPTransportTestRequests.requestBody(
                id: 4,
                method: "tools/list",
                params: MCPTransportTestRequests.params()
            )
            let request = MCPTransportTestRequests.raw(
                port: port,
                headers: [
                    ("Content-Type", "application/json"),
                    ("Authorization", MCPTransportTestRequests.bearerToken),
                    (MCPHttpHeaderValidator.methodHeader, "tools/list")
                ],
                body: body
            )
            let response = try await exchange(port: port, request: request)

            #expect(response.statusCode == 400)
            #expect(try response.jsonRpcError().code == JsonRpcErrorCode.headerMismatch)
        }
    }

    @Test("A missing Mcp-Method header is -32020 with HTTP 400")
    func missingMethodHeader() async throws {
        try await MCPTransportTestHarness.withServer { port in
            let body = try MCPTransportTestRequests.requestBody(
                id: 5,
                method: "tools/list",
                params: MCPTransportTestRequests.params()
            )
            let request = MCPTransportTestRequests.raw(
                port: port,
                headers: [
                    ("Content-Type", "application/json"),
                    ("Authorization", MCPTransportTestRequests.bearerToken),
                    (MCPHttpHeaderValidator.protocolVersionHeader, MCPTransportTestRequests.protocolVersion)
                ],
                body: body
            )
            let response = try await exchange(port: port, request: request)

            #expect(response.statusCode == 400)
            #expect(try response.jsonRpcError().code == JsonRpcErrorCode.headerMismatch)
        }
    }

    @Test("A missing Mcp-Name header on tools/call is -32020 with HTTP 400")
    func missingNameHeader() async throws {
        try await MCPTransportTestHarness.withServer { port in
            let body = try MCPTransportTestRequests.requestBody(
                id: 6,
                method: "tools/call",
                params: MCPTransportTestRequests.params(["name": .string("list_tables")])
            )
            let request = MCPTransportTestRequests.raw(
                port: port,
                headers: MCPTransportTestRequests.standardHeaders(method: "tools/call"),
                body: body
            )
            let response = try await exchange(port: port, request: request)

            #expect(response.statusCode == 400)
            #expect(try response.jsonRpcError().code == JsonRpcErrorCode.headerMismatch)
        }
    }

    @Test("A header value that disagrees with the body is -32020")
    func headerDisagreesWithBody() async throws {
        try await MCPTransportTestHarness.withServer { port in
            let body = try MCPTransportTestRequests.requestBody(
                id: 7,
                method: "tools/call",
                params: MCPTransportTestRequests.params(["name": .string("list_tables")])
            )
            let request = MCPTransportTestRequests.raw(
                port: port,
                headers: MCPTransportTestRequests.standardHeaders(method: "tools/call", name: "run_query"),
                body: body
            )
            let response = try await exchange(port: port, request: request)

            #expect(response.statusCode == 400)
            let error = try response.jsonRpcError()
            #expect(error.code == JsonRpcErrorCode.headerMismatch)
            #expect(error.message.contains("Mcp-Name"))
        }
    }

    @Test("Header names compare case-insensitively")
    func headerNamesAreCaseInsensitive() async throws {
        try await MCPTransportTestHarness.withServer { port in
            let body = try MCPTransportTestRequests.requestBody(
                id: 8,
                method: "tools/call",
                params: MCPTransportTestRequests.params(["name": .string("list_tables")])
            )
            let request = MCPTransportTestRequests.raw(
                port: port,
                headers: [
                    ("content-type", "application/json"),
                    ("authorization", MCPTransportTestRequests.bearerToken),
                    ("mcp-protocol-version", MCPTransportTestRequests.protocolVersion),
                    ("mcp-method", "tools/call"),
                    ("mcp-name", "list_tables")
                ],
                body: body
            )
            let response = try await exchange(port: port, request: request)

            #expect(response.statusCode == 200)
        }
    }

    @Test("Integer parameter headers compare numerically, so 42.0 matches 42")
    func integerParametersCompareNumerically() async throws {
        try await MCPTransportTestHarness.withServer { port in
            let body = try MCPTransportTestRequests.requestBody(
                id: 9,
                method: "tools/call",
                params: MCPTransportTestRequests.params([
                    "name": .string("list_tables"),
                    "arguments": .object(["limit": .int(42)])
                ])
            )
            var headers = MCPTransportTestRequests.standardHeaders(method: "tools/call", name: "list_tables")
            headers.append(("Mcp-Param-Limit", "42.0"))
            let response = try await exchange(
                port: port,
                request: MCPTransportTestRequests.raw(port: port, headers: headers, body: body)
            )

            #expect(response.statusCode == 200)
        }
    }

    @Test("A Base64 sentinel Mcp-Name is decoded before it is compared")
    func base64NameIsDecoded() async throws {
        try await MCPTransportTestHarness.withServer { port in
            let toolName = "查询 表"
            let body = try MCPTransportTestRequests.requestBody(
                id: 10,
                method: "tools/call",
                params: MCPTransportTestRequests.params(["name": .string(toolName)])
            )
            let headers = MCPTransportTestRequests.standardHeaders(method: "tools/call", name: toolName)
            let encodedName = headers.first { $0.0 == MCPHttpHeaderValidator.nameHeader }?.1
            #expect(encodedName == MCPBase64Sentinel.encode(toolName))

            let response = try await exchange(
                port: port,
                request: MCPTransportTestRequests.raw(port: port, headers: headers, body: body)
            )
            #expect(response.statusCode == 200)
        }
    }

    @Test("An unknown method answers HTTP 404 carrying a JSON-RPC -32601 body")
    func unknownMethodIsNotFound() async throws {
        try await MCPTransportTestHarness.withServer { port in
            let request = try MCPTransportTestRequests.modernPost(port: port, id: 11, method: "tools/teleport")
            let response = try await exchange(port: port, request: request)

            #expect(response.statusCode == 404)
            #expect(response.isJsonRpcEnvelope(), "the body distinguishes a modern server from a legacy 404")
            #expect(try response.jsonRpcError().code == JsonRpcErrorCode.methodNotFound)
        }
    }

    @Test("An unsupported protocol version answers HTTP 400 with -32022 and the supported list")
    func unsupportedProtocolVersion() async throws {
        try await MCPTransportTestHarness.withServer { port in
            let request = try MCPTransportTestRequests.modernPost(
                port: port,
                id: 12,
                method: "tools/list",
                version: "1999-01-01"
            )
            let response = try await exchange(port: port, request: request)

            #expect(response.statusCode == 400)
            let error = try response.jsonRpcError()
            #expect(error.code == JsonRpcErrorCode.unsupportedProtocolVersion)
            let supported = error.data?["supported"]?.arrayValue?.compactMap(\.stringValue)
            #expect(supported == MCPProtocolVersion.supportedRawValues)
            #expect(error.data?["requested"]?.stringValue == "1999-01-01")
        }
    }

    @Test("An absent Origin is allowed because native clients send none")
    func absentOriginIsAllowed() async throws {
        try await MCPTransportTestHarness.withServer { port in
            let request = try MCPTransportTestRequests.modernPost(port: port, id: 13, method: "tools/list")
            let response = try await exchange(port: port, request: request)

            #expect(response.statusCode == 200)
            #expect(!response.hasHeader("Access-Control-Allow-Origin"))
        }
    }

    @Test("A present but disallowed Origin is HTTP 403")
    func disallowedOriginIsForbidden() async throws {
        try await MCPTransportTestHarness.withServer { port in
            let request = try MCPTransportTestRequests.modernPost(
                port: port,
                id: 14,
                method: "tools/list",
                extraHeaders: [("Origin", "https://evil.example.com")]
            )
            let response = try await exchange(port: port, request: request)

            #expect(response.statusCode == 403)
            #expect(try response.plainJsonField("error") == "forbidden_origin")
        }
    }

    @Test("Localhost on an arbitrary port is not an allowed Origin")
    func localhostOriginIsForbidden() async throws {
        try await MCPTransportTestHarness.withServer { port in
            for origin in ["http://localhost", "http://localhost:3000", "http://127.0.0.1:5173"] {
                let request = try MCPTransportTestRequests.modernPost(
                    port: port,
                    id: 15,
                    method: "tools/list",
                    extraHeaders: [("Origin", origin)]
                )
                let response = try await exchange(port: port, request: request)
                #expect(response.statusCode == 403, "\(origin) must not reach the MCP endpoint")
            }
        }
    }

    @Test("An OPTIONS preflight from an allowed origin returns 204 with CORS headers")
    func optionsPreflightFromAllowedOrigin() async throws {
        try await MCPTransportTestHarness.withServer { port in
            let request = MCPTransportTestRequests.raw(
                method: "OPTIONS",
                port: port,
                headers: [("Origin", "https://claude.ai")],
                body: nil,
                includeContentLength: false
            )
            let response = try await exchange(port: port, request: request)

            #expect(response.statusCode == 204)
            #expect(response.header("Access-Control-Allow-Origin") == "https://claude.ai")
            #expect(response.header("Vary") == "Origin")
            #expect(response.header("Allow")?.contains("POST") == true)
        }
    }

    @Test("An OPTIONS preflight without an Origin returns 204 without CORS headers")
    func optionsPreflightWithoutOrigin() async throws {
        try await MCPTransportTestHarness.withServer { port in
            let request = MCPTransportTestRequests.raw(
                method: "OPTIONS",
                port: port,
                headers: [],
                body: nil,
                includeContentLength: false
            )
            let response = try await exchange(port: port, request: request)

            #expect(response.statusCode == 204)
            #expect(!response.hasHeader("Access-Control-Allow-Origin"))
        }
    }

    @Test("An accepted notification answers 202 with Content-Length: 0")
    func notificationIsAccepted() async throws {
        try await MCPTransportTestHarness.withServer { port in
            let body = try MCPTransportTestRequests.notificationBody(
                method: "notifications/progress",
                params: MCPTransportTestRequests.params(["progress": .double(0.5)])
            )
            let request = MCPTransportTestRequests.raw(
                port: port,
                headers: MCPTransportTestRequests.standardHeaders(method: "notifications/progress"),
                body: body
            )
            let response = try await exchange(port: port, request: request)

            #expect(response.statusCode == 202)
            #expect(response.header("Content-Length") == "0")
            #expect(response.body.isEmpty)
        }
    }

    @Test("An unknown path answers a plain 404 that is not a JSON-RPC envelope")
    func unknownPathIsPlainNotFound() async throws {
        try await MCPTransportTestHarness.withServer { port in
            for path in ["/foo", "/.well-known/oauth-protected-resource", "/register"] {
                let request = MCPTransportTestRequests.raw(
                    method: "POST",
                    path: path,
                    port: port,
                    headers: [("Content-Type", "application/json")],
                    body: Data("{}".utf8)
                )
                let response = try await exchange(port: port, request: request)
                #expect(response.statusCode == 404, "\(path) must be 404")
                #expect(!response.isJsonRpcEnvelope(), "\(path) must answer a plain error")
                #expect(try response.plainJsonField("error") == "not_found")
            }
        }
    }

    @Test("A body that is not application/json answers 415")
    func nonJsonBodyIsUnsupportedMediaType() async throws {
        try await MCPTransportTestHarness.withServer { port in
            let request = MCPTransportTestRequests.raw(
                port: port,
                headers: [("Content-Type", "text/plain")],
                body: Data("hello".utf8)
            )
            let response = try await exchange(port: port, request: request)

            #expect(response.statusCode == 415)
        }
    }

    @Test("A JSON-RPC response sent by the client is refused")
    func clientSentResponseIsRefused() async throws {
        try await MCPTransportTestHarness.withServer { port in
            let body = try JsonRpcCodec.encode(
                .successResponse(JsonRpcSuccessResponse(id: .number(1), result: .object([:])))
            )
            let request = MCPTransportTestRequests.raw(
                port: port,
                headers: [
                    ("Content-Type", "application/json"),
                    ("Authorization", MCPTransportTestRequests.bearerToken)
                ],
                body: body
            )
            let response = try await exchange(port: port, request: request)

            #expect(response.statusCode == 400)
            #expect(try response.jsonRpcError().code == JsonRpcErrorCode.invalidRequest)
        }
    }

    @Test("A body larger than the cap is refused before any body byte is read")
    func oversizedBodyIsRefusedWhileReading() async throws {
        let limits = MCPHttpServerLimits(
            maxRequestBodyBytes: 1_024,
            maxHeaderBytes: 16 * 1_024,
            connectionTimeout: .seconds(10)
        )
        try await MCPTransportTestHarness.withServer(limits: limits) { port in
            let head = MCPTransportTestRequests.raw(
                port: port,
                headers: [
                    ("Content-Type", "application/json"),
                    ("Content-Length", "1048576")
                ],
                body: nil,
                includeContentLength: false
            )
            let client = RawHttpTestClient(port: port)
            try await client.connect()
            defer { Task { await client.close() } }
            try await client.send(head)

            let response = try await client.readResponse()
            #expect(response.statusCode == 413)
            #expect(try response.jsonRpcError().code == JsonRpcErrorCode.tooLarge)
        }
    }

    @Test("A chunked body is decoded rather than read as an empty body")
    func chunkedBodyIsDecoded() async throws {
        try await MCPTransportTestHarness.withServer { port in
            let body = try MCPTransportTestRequests.requestBody(
                id: 16,
                method: "tools/list",
                params: MCPTransportTestRequests.params()
            )
            var headers = MCPTransportTestRequests.standardHeaders(method: "tools/list")
            headers.append(("Transfer-Encoding", "chunked"))
            var request = MCPTransportTestRequests.raw(
                port: port,
                headers: headers,
                body: nil,
                includeContentLength: false
            )
            request.append(Data("\(String(body.count, radix: 16))\r\n".utf8))
            request.append(body)
            request.append(Data("\r\n0\r\n\r\n".utf8))

            let response = try await exchange(port: port, request: request)
            #expect(response.statusCode == 200)
            #expect(try response.jsonRpcResult()["method"]?.stringValue == "tools/list")
        }
    }

    @Test("A chunk larger than the body cap is refused")
    func oversizedChunkIsRefused() async throws {
        let limits = MCPHttpServerLimits(
            maxRequestBodyBytes: 64,
            maxHeaderBytes: 16 * 1_024,
            connectionTimeout: .seconds(10)
        )
        try await MCPTransportTestHarness.withServer(limits: limits) { port in
            var headers = MCPTransportTestRequests.standardHeaders(method: "tools/list")
            headers.append(("Transfer-Encoding", "chunked"))
            var request = MCPTransportTestRequests.raw(
                port: port,
                headers: headers,
                body: nil,
                includeContentLength: false
            )
            request.append(Data("1000\r\n".utf8))

            let response = try await exchange(port: port, request: request)
            #expect(response.statusCode == 413)
        }
    }

    @Test("An unsupported Transfer-Encoding is refused explicitly")
    func unsupportedTransferEncodingIsRefused() async throws {
        try await MCPTransportTestHarness.withServer { port in
            var headers = MCPTransportTestRequests.standardHeaders(method: "tools/list")
            headers.append(("Transfer-Encoding", "gzip"))
            let request = MCPTransportTestRequests.raw(
                port: port,
                headers: headers,
                body: nil,
                includeContentLength: false
            )
            let response = try await exchange(port: port, request: request)

            #expect(response.statusCode == 501)
            #expect(try response.jsonRpcError().code == JsonRpcErrorCode.invalidRequest)
        }
    }

    @Test("A Host header that is not loopback is refused with 403")
    func nonLoopbackHostIsForbidden() async throws {
        try await MCPTransportTestHarness.withServer { port in
            let request = try MCPTransportTestRequests.modernPost(
                port: port,
                id: 17,
                method: "tools/list",
                host: "attacker.test"
            )
            let response = try await exchange(port: port, request: request)

            #expect(response.statusCode == 403)
            #expect(try response.plainJsonField("error") == "forbidden_host")
        }
    }

    @Test("A missing Authorization header answers 401 with a bearer challenge")
    func missingAuthorizationIsUnauthorized() async throws {
        let authenticator = StubBearerAuthenticator(validToken: "valid")
        try await MCPTransportTestHarness.withServer(authenticator: authenticator) { port in
            let body = try MCPTransportTestRequests.requestBody(
                id: 18,
                method: "tools/list",
                params: MCPTransportTestRequests.params()
            )
            var headers = MCPTransportTestRequests.standardHeaders(method: "tools/list")
            headers.removeAll { $0.0 == "Authorization" }
            let response = try await exchange(
                port: port,
                request: MCPTransportTestRequests.raw(port: port, headers: headers, body: body)
            )

            #expect(response.statusCode == 401)
            #expect(response.header("WWW-Authenticate")?.hasPrefix("Bearer") == true)
            #expect(try response.jsonRpcError().code == JsonRpcErrorCode.unauthenticated)
        }
    }

    @Test("Repeated bad tokens answer 429 with Retry-After")
    func rateLimitedRequestCarriesRetryAfter() async throws {
        let authenticator = StubBearerAuthenticator(validToken: "valid", maxAttempts: 2)
        try await MCPTransportTestHarness.withServer(authenticator: authenticator) { port in
            let body = try MCPTransportTestRequests.requestBody(
                id: 19,
                method: "tools/list",
                params: MCPTransportTestRequests.params()
            )
            var headers = MCPTransportTestRequests.standardHeaders(method: "tools/list")
            headers.removeAll { $0.0 == "Authorization" }
            headers.append(("Authorization", "Bearer wrong-token"))
            let request = MCPTransportTestRequests.raw(port: port, headers: headers, body: body)

            for _ in 0..<2 {
                _ = try await exchange(port: port, request: request)
            }
            let response = try await exchange(port: port, request: request)

            #expect(response.statusCode == 429)
            #expect(response.header("Retry-After") == "30")
        }
    }

    @Test("A connection beyond the concurrency limit is refused with 503")
    func overCapacityConnectionIsRefused() async throws {
        let limits = MCPHttpServerLimits(
            maxRequestBodyBytes: 1_024 * 1_024,
            maxHeaderBytes: 16 * 1_024,
            connectionTimeout: .seconds(10),
            maxConcurrentConnections: 1
        )
        try await MCPTransportTestHarness.withServer(limits: limits) { port in
            let holder = RawHttpTestClient(port: port)
            try await holder.connect()
            defer { Task { await holder.close() } }
            let held = try MCPTransportTestRequests.modernPost(port: port, id: 20, method: "tools/list")
            try await holder.send(held)
            let heldResponse = try await holder.readResponse()
            #expect(heldResponse.statusCode == 200)

            let extra = RawHttpTestClient(port: port)
            try await extra.connect()
            defer { Task { await extra.close() } }
            let response = try await extra.readResponse()

            #expect(response.statusCode == 503)
            #expect(response.header("Retry-After") == "1")
            #expect(try response.plainJsonField("error") == "too_many_connections")
        }
    }

    @Test("An SSE response writes its head exactly once and disables proxy buffering")
    func sseHeadIsWrittenOnce() async throws {
        let handler: @Sendable (MCPInboundExchange) async -> Void = { exchange in
            guard case .request(let request) = exchange.message else { return }
            await exchange.responder.beginStream()
            await exchange.responder.beginStream()
            await exchange.responder.emit(
                .notification(JsonRpcNotification(method: "notifications/progress", params: nil))
            )
            await exchange.responder.respond(
                .successResponse(JsonRpcSuccessResponse(id: request.id, result: .object(["ok": .bool(true)])))
            )
        }

        try await MCPTransportTestHarness.withServer(handler: handler) { port in
            let client = RawHttpTestClient(port: port)
            try await client.connect()
            defer { Task { await client.close() } }
            try await client.send(
                try MCPTransportTestRequests.modernPost(port: port, id: 21, method: "tools/list")
            )

            let head = try await client.readResponse()
            #expect(head.statusCode == 200)
            #expect(head.header("Content-Type") == "text/event-stream")
            #expect(head.header("X-Accel-Buffering") == "no")
            #expect(!head.hasHeader("Content-Length"))

            let notification = try await client.readUntil("\n\n")
            #expect(notification.contains("notifications/progress"))
            let final = try await client.readUntil("\n\n")
            #expect(final.contains("\"ok\":true"))

            _ = await client.waitForClose(timeout: .seconds(3))
            let everything = await client.receivedText()
            let heads = everything.components(separatedBy: "HTTP/1.1 ").count - 1
            #expect(heads == 1, "the response head must be written exactly once")
        }
    }

    @Test("Closing the response stream cancels the request")
    func closingTheStreamCancelsTheRequest() async throws {
        let signal = TransportTestSignal()
        let handler: @Sendable (MCPInboundExchange) async -> Void = { exchange in
            guard case .request(let request) = exchange.message else { return }
            await exchange.responder.beginStream()
            await signal.raise("streaming")
            let deadline = TransportTestTime.deadline(.seconds(5))
            var disconnected = false
            while Date() < deadline {
                if await exchange.responder.clientDisconnected() {
                    disconnected = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            if disconnected {
                await signal.raise("disconnected")
            }
            await exchange.responder.respond(
                .successResponse(JsonRpcSuccessResponse(id: request.id, result: .object([:])))
            )
        }

        try await MCPTransportTestHarness.withServer(handler: handler) { port in
            let client = RawHttpTestClient(port: port)
            try await client.connect()
            try await client.send(
                try MCPTransportTestRequests.modernPost(port: port, id: 22, method: "subscriptions/listen")
            )
            _ = try await client.readResponse()
            #expect(await signal.wait(for: "streaming"))

            await client.close()
            #expect(await signal.wait(for: "disconnected", timeout: .seconds(5)))
        }
    }
}
