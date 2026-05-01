//
//  MCPRouterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("MCP Router")
struct MCPRouterTests {
    private final class StubHandler: MCPRouteHandler, @unchecked Sendable {
        let methods: [HTTPRequest.Method]
        let path: String
        private let result: MCPRouter.RouteResult
        private(set) var invocationCount: Int = 0
        private(set) var lastRequest: HTTPRequest?

        init(methods: [HTTPRequest.Method], path: String, result: MCPRouter.RouteResult = .accepted) {
            self.methods = methods
            self.path = path
            self.result = result
        }

        func handle(_ request: HTTPRequest) async -> MCPRouter.RouteResult {
            invocationCount += 1
            lastRequest = request
            return result
        }
    }

    private func makeRequest(
        method: HTTPRequest.Method,
        path: String,
        body: Data? = nil
    ) -> HTTPRequest {
        HTTPRequest(method: method, path: path, headers: [:], body: body, remoteIP: nil)
    }

    @Test("OPTIONS preflight returns noContent regardless of path")
    func optionsPreflightAlwaysNoContent() async {
        let mcpHandler = StubHandler(methods: [.post], path: "/mcp", result: .accepted)
        let router = MCPRouter(routes: [mcpHandler])

        let optionsAtMcp = makeRequest(method: .options, path: "/mcp")
        let result1 = await router.handle(optionsAtMcp)
        guard case .noContent = result1 else {
            Issue.record("Expected .noContent for OPTIONS /mcp, got \(result1)")
            return
        }

        let optionsAtUnknown = makeRequest(method: .options, path: "/unknown/path")
        let result2 = await router.handle(optionsAtUnknown)
        guard case .noContent = result2 else {
            Issue.record("Expected .noContent for OPTIONS /unknown, got \(result2)")
            return
        }

        #expect(mcpHandler.invocationCount == 0)
    }

    @Test("POST /mcp dispatches to MCP protocol handler")
    func postMcpDispatchesToProtocolHandler() async {
        let mcpHandler = StubHandler(methods: [.get, .post, .delete], path: "/mcp", result: .accepted)
        let exchangeHandler = StubHandler(methods: [.post], path: "/v1/integrations/exchange", result: .accepted)
        let router = MCPRouter(routes: [mcpHandler, exchangeHandler])

        let request = makeRequest(method: .post, path: "/mcp")
        _ = await router.handle(request)

        #expect(mcpHandler.invocationCount == 1)
        #expect(exchangeHandler.invocationCount == 0)
    }

    @Test("POST /v1/integrations/exchange dispatches to exchange handler")
    func postExchangeDispatchesToExchangeHandler() async {
        let mcpHandler = StubHandler(methods: [.get, .post, .delete], path: "/mcp", result: .accepted)
        let exchangeHandler = StubHandler(methods: [.post], path: "/v1/integrations/exchange", result: .accepted)
        let router = MCPRouter(routes: [mcpHandler, exchangeHandler])

        let request = makeRequest(method: .post, path: "/v1/integrations/exchange")
        _ = await router.handle(request)

        #expect(exchangeHandler.invocationCount == 1)
        #expect(mcpHandler.invocationCount == 0)
    }

    @Test("Path with query string still matches canonical route")
    func queryStringMatchesCanonicalPath() async {
        let mcpHandler = StubHandler(methods: [.post], path: "/mcp", result: .accepted)
        let router = MCPRouter(routes: [mcpHandler])

        let request = makeRequest(method: .post, path: "/mcp?session=abc")
        _ = await router.handle(request)

        #expect(mcpHandler.invocationCount == 1)
    }

    @Test("Unknown path returns 404 httpError")
    func unknownPathReturnsNotFound() async {
        let mcpHandler = StubHandler(methods: [.post], path: "/mcp", result: .accepted)
        let router = MCPRouter(routes: [mcpHandler])

        let request = makeRequest(method: .post, path: "/totally/unknown")
        let result = await router.handle(request)

        guard case .httpError(let status, _) = result else {
            Issue.record("Expected .httpError, got \(result)")
            return
        }
        #expect(status == 404)
        #expect(mcpHandler.invocationCount == 0)
    }

    @Test("Method mismatch on registered path returns 404")
    func methodMismatchReturnsNotFound() async {
        let exchangeHandler = StubHandler(methods: [.post], path: "/v1/integrations/exchange", result: .accepted)
        let router = MCPRouter(routes: [exchangeHandler])

        let request = makeRequest(method: .get, path: "/v1/integrations/exchange")
        let result = await router.handle(request)

        guard case .httpError(let status, _) = result else {
            Issue.record("Expected .httpError, got \(result)")
            return
        }
        #expect(status == 404)
        #expect(exchangeHandler.invocationCount == 0)
    }

    @Test(".well-known requests return 404 immediately")
    func wellKnownReturnsNotFound() async {
        let mcpHandler = StubHandler(methods: [.get], path: "/.well-known/oauth", result: .accepted)
        let router = MCPRouter(routes: [mcpHandler])

        let request = makeRequest(method: .get, path: "/.well-known/oauth")
        let result = await router.handle(request)

        guard case .httpError(let status, _) = result else {
            Issue.record("Expected .httpError, got \(result)")
            return
        }
        #expect(status == 404)
        #expect(mcpHandler.invocationCount == 0)
    }

    @Test("Handler receives the original request")
    func handlerReceivesOriginalRequest() async {
        let mcpHandler = StubHandler(methods: [.post], path: "/mcp", result: .accepted)
        let router = MCPRouter(routes: [mcpHandler])

        let body = Data("{\"hello\":\"world\"}".utf8)
        let request = HTTPRequest(
            method: .post,
            path: "/mcp",
            headers: ["content-type": "application/json"],
            body: body,
            remoteIP: "10.0.0.1"
        )
        _ = await router.handle(request)

        #expect(mcpHandler.lastRequest?.path == "/mcp")
        #expect(mcpHandler.lastRequest?.method == .post)
        #expect(mcpHandler.lastRequest?.body == body)
        #expect(mcpHandler.lastRequest?.remoteIP == "10.0.0.1")
    }
}
