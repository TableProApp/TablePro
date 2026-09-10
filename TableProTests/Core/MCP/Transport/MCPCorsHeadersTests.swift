import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("MCP CORS Headers")
struct MCPCorsHeadersTests {
    private func value(_ headers: [(String, String)], _ name: String) -> String? {
        headers.first { $0.0.lowercased() == name.lowercased() }?.1
    }

    @Test("The two hosted MCP clients are the only allowed origins")
    func allowedOrigins() {
        #expect(MCPCorsHeaders.isAllowed(origin: "https://claude.ai"))
        #expect(MCPCorsHeaders.isAllowed(origin: "https://app.cursor.com"))
        #expect(!MCPCorsHeaders.isAllowed(origin: "https://evil.example.com"))
        #expect(!MCPCorsHeaders.isAllowed(origin: "https://notclaude.ai"))
        #expect(!MCPCorsHeaders.isAllowed(origin: "https://claude.ai.evil.example.com"))
    }

    @Test("Localhost is not an allowed origin on any port")
    func localhostIsNotAllowed() {
        #expect(!MCPCorsHeaders.isAllowed(origin: "http://localhost"))
        #expect(!MCPCorsHeaders.isAllowed(origin: "http://localhost:3000"))
        #expect(!MCPCorsHeaders.isAllowed(origin: "https://localhost:3000"))
        #expect(!MCPCorsHeaders.isAllowed(origin: "http://127.0.0.1:5173"))
    }

    @Test("Only https on the default port is accepted")
    func schemeAndPortAreChecked() {
        #expect(!MCPCorsHeaders.isAllowed(origin: "http://claude.ai"))
        #expect(MCPCorsHeaders.isAllowed(origin: "https://claude.ai:443"))
        #expect(!MCPCorsHeaders.isAllowed(origin: "https://claude.ai:8443"))
    }

    @Test("An origin carrying a path is not a valid origin")
    func originWithPathIsRejected() {
        #expect(!MCPCorsHeaders.isAllowed(origin: "https://claude.ai/"))
        #expect(!MCPCorsHeaders.isAllowed(origin: "https://claude.ai/mcp"))
    }

    @Test("Host comparison ignores case")
    func hostComparisonIgnoresCase() {
        #expect(MCPCorsHeaders.isAllowed(origin: "https://Claude.AI"))
    }

    @Test("An allowed origin is echoed back and varied on")
    func allowedOriginProducesHeaders() {
        let headers = MCPCorsHeaders.headers(forOrigin: "https://claude.ai")

        #expect(value(headers, "Access-Control-Allow-Origin") == "https://claude.ai")
        #expect(value(headers, "Vary") == "Origin")
        #expect(value(headers, "Access-Control-Allow-Methods") == "POST, OPTIONS")
        #expect(value(headers, "Access-Control-Max-Age") == "86400")
    }

    @Test("The advertised request headers cover every header a modern POST must carry")
    func advertisedRequestHeaders() throws {
        let headers = MCPCorsHeaders.headers(forOrigin: "https://claude.ai")
        let allowed = try #require(value(headers, "Access-Control-Allow-Headers"))

        for required in [
            "Authorization",
            "Content-Type",
            "Accept",
            MCPHttpHeaderValidator.protocolVersionHeader,
            MCPHttpHeaderValidator.methodHeader,
            MCPHttpHeaderValidator.nameHeader
        ] {
            #expect(allowed.contains(required), "\(required) must be allowed on a preflight")
        }
    }

    @Test("The allowed methods never include the removed GET stream endpoint")
    func allowedMethodsExcludeGet() throws {
        let headers = MCPCorsHeaders.headers(forOrigin: "https://claude.ai")
        let methods = try #require(value(headers, "Access-Control-Allow-Methods"))

        #expect(!methods.contains("GET"))
        #expect(!methods.contains("DELETE"))
    }

    @Test("A missing, empty or disallowed origin produces no CORS headers")
    func noHeadersWithoutAnAllowedOrigin() {
        #expect(MCPCorsHeaders.headers(forOrigin: nil).isEmpty)
        #expect(MCPCorsHeaders.headers(forOrigin: "").isEmpty)
        #expect(MCPCorsHeaders.headers(forOrigin: "https://evil.example.com").isEmpty)
        #expect(MCPCorsHeaders.headers(forOrigin: "http://localhost:3000").isEmpty)
    }

    @Test("A malformed origin is rejected rather than parsed loosely")
    func malformedOriginIsRejected() {
        #expect(!MCPCorsHeaders.isAllowed(origin: "claude.ai"))
        #expect(!MCPCorsHeaders.isAllowed(origin: "://claude.ai"))
        #expect(!MCPCorsHeaders.isAllowed(origin: "null"))
    }
}
