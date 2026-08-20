import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("MCP HTTP Header Validator")
struct MCPHttpHeaderValidatorTests {
    private func makeHead(_ pairs: [(String, String)]) -> HttpRequestHead {
        HttpRequestHead(method: .post, path: "/mcp", httpVersion: "HTTP/1.1", headers: HttpHeaders(pairs))
    }

    private func modernMeta(_ version: String = "2026-07-28") -> JsonValue {
        .object([
            MCPMetaKeys.protocolVersion: .string(version),
            MCPMetaKeys.clientCapabilities: .object([:])
        ])
    }

    private func toolCall(name: String = "run_query") -> JsonRpcMessage {
        .request(JsonRpcRequest(
            id: .number(1),
            method: "tools/call",
            params: .object([
                "name": .string(name),
                "arguments": .object([
                    "region": .string("us-west1"),
                    "limit": .int(42),
                    "dry": .bool(true)
                ]),
                "_meta": modernMeta()
            ])
        ))
    }

    @Test("Matching headers pass, comparing integers numerically")
    func matchingHeadersPass() {
        let head = makeHead([
            ("mcp-protocol-version", "2026-07-28"),
            ("Mcp-Method", "tools/call"),
            ("Mcp-Name", "run_query"),
            ("Mcp-Param-Region", "us-west1"),
            ("Mcp-Param-Limit", "42.0"),
            ("Mcp-Param-Dry", "true")
        ])
        #expect(MCPHttpHeaderValidator.validate(head: head, message: toolCall()) == nil)
    }

    @Test("Missing or mismatched standard headers are -32020")
    func standardHeaderFailures() {
        let missingVersion = makeHead([("Mcp-Method", "tools/call"), ("Mcp-Name", "run_query")])
        #expect(MCPHttpHeaderValidator.validate(head: missingVersion, message: toolCall())?.code
            == JsonRpcErrorCode.headerMismatch)

        let wrongVersion = makeHead([
            ("MCP-Protocol-Version", "2025-06-18"),
            ("Mcp-Method", "tools/call"),
            ("Mcp-Name", "run_query")
        ])
        #expect(MCPHttpHeaderValidator.validate(head: wrongVersion, message: toolCall())?.code
            == JsonRpcErrorCode.headerMismatch)

        let wrongMethod = makeHead([
            ("MCP-Protocol-Version", "2026-07-28"),
            ("Mcp-Method", "tools/list"),
            ("Mcp-Name", "run_query")
        ])
        #expect(MCPHttpHeaderValidator.validate(head: wrongMethod, message: toolCall())?.code
            == JsonRpcErrorCode.headerMismatch)

        let missingName = makeHead([("MCP-Protocol-Version", "2026-07-28"), ("Mcp-Method", "tools/call")])
        #expect(MCPHttpHeaderValidator.validate(head: missingName, message: toolCall())?.code
            == JsonRpcErrorCode.headerMismatch)
    }

    @Test("Header mismatch carries HTTP 400")
    func mismatchIsBadRequest() {
        let head = makeHead([
            ("MCP-Protocol-Version", "2026-07-28"),
            ("Mcp-Method", "tools/call"),
            ("Mcp-Name", "other_tool")
        ])
        let failure = MCPHttpHeaderValidator.validate(head: head, message: toolCall())
        #expect(failure?.httpStatus == .badRequest)
    }

    @Test("Parameter headers are validated against the body")
    func parameterHeaders() {
        let mismatch = makeHead([
            ("MCP-Protocol-Version", "2026-07-28"),
            ("Mcp-Method", "tools/call"),
            ("Mcp-Name", "run_query"),
            ("Mcp-Param-Region", "eu-west1")
        ])
        #expect(MCPHttpHeaderValidator.validate(head: mismatch, message: toolCall())?.code
            == JsonRpcErrorCode.headerMismatch)

        let unknown = makeHead([
            ("MCP-Protocol-Version", "2026-07-28"),
            ("Mcp-Method", "tools/call"),
            ("Mcp-Name", "run_query"),
            ("Mcp-Param-Nope", "value")
        ])
        #expect(MCPHttpHeaderValidator.validate(head: unknown, message: toolCall())?.code
            == JsonRpcErrorCode.headerMismatch)
    }

    @Test("Base64 sentinel values are decoded before comparison")
    func sentinelValuesDecode() {
        let message = JsonRpcMessage.request(JsonRpcRequest(
            id: .number(7),
            method: "tools/call",
            params: .object([
                "name": .string("查询"),
                "arguments": .object(["text": .string(" padded ")]),
                "_meta": modernMeta()
            ])
        ))
        let head = makeHead([
            ("MCP-Protocol-Version", "2026-07-28"),
            ("Mcp-Method", "tools/call"),
            ("Mcp-Name", MCPBase64Sentinel.encodeIfNeeded("查询")),
            ("Mcp-Param-Text", MCPBase64Sentinel.encodeIfNeeded(" padded "))
        ])
        #expect(MCPHttpHeaderValidator.validate(head: head, message: message) == nil)
    }

    @Test("resources/read matches params.uri and tools/list needs no name")
    func nameSourceFields() {
        let read = JsonRpcMessage.request(JsonRpcRequest(
            id: .number(2),
            method: "resources/read",
            params: .object(["uri": .string("tablepro://c/1/table/users"), "_meta": modernMeta()])
        ))
        let readHead = makeHead([
            ("MCP-Protocol-Version", "2026-07-28"),
            ("Mcp-Method", "resources/read"),
            ("Mcp-Name", "tablepro://c/1/table/users")
        ])
        #expect(MCPHttpHeaderValidator.validate(head: readHead, message: read) == nil)

        let list = JsonRpcMessage.request(JsonRpcRequest(
            id: .number(3),
            method: "tools/list",
            params: .object(["_meta": modernMeta()])
        ))
        let listHead = makeHead([("MCP-Protocol-Version", "2026-07-28"), ("Mcp-Method", "tools/list")])
        #expect(MCPHttpHeaderValidator.validate(head: listHead, message: list) == nil)
    }

    @Test("Host header must be loopback and match the bound port")
    func hostGuard() {
        func hostHead(_ value: String) -> HttpRequestHead {
            makeHead([("Host", value)])
        }
        #expect(MCPHttpHeaderValidator.hostIsLoopback(hostHead("127.0.0.1:23508"), expectedPort: 23_508))
        #expect(MCPHttpHeaderValidator.hostIsLoopback(hostHead("localhost:23508"), expectedPort: 23_508))
        #expect(MCPHttpHeaderValidator.hostIsLoopback(hostHead("[::1]:23508"), expectedPort: 23_508))
        #expect(MCPHttpHeaderValidator.hostIsLoopback(hostHead("localhost"), expectedPort: 23_508))
        #expect(!MCPHttpHeaderValidator.hostIsLoopback(hostHead("attacker.test:23508"), expectedPort: 23_508))
        #expect(!MCPHttpHeaderValidator.hostIsLoopback(hostHead("127.0.0.1:9999"), expectedPort: 23_508))
        #expect(!MCPHttpHeaderValidator.hostIsLoopback(makeHead([]), expectedPort: 23_508))
    }

    @Test("A Base64 sentinel resource URI is decoded before comparison")
    func sentinelResourceUri() {
        let uri = "tablepro://c/1/table/пользователи"
        let read = JsonRpcMessage.request(JsonRpcRequest(
            id: .number(11),
            method: "resources/read",
            params: .object(["uri": .string(uri), "_meta": modernMeta()])
        ))
        let head = makeHead([
            ("MCP-Protocol-Version", "2026-07-28"),
            ("Mcp-Method", "resources/read"),
            ("Mcp-Name", MCPBase64Sentinel.encode(uri))
        ])
        #expect(MCPHttpHeaderValidator.validate(head: head, message: read) == nil)
    }

    @Test("prompts/get carries a name header like tools/call")
    func promptsGetNeedsAName() {
        let params = JsonValue.object(["name": .string("explain_query"), "_meta": modernMeta()])
        let message = JsonRpcMessage.request(JsonRpcRequest(id: .number(12), method: "prompts/get", params: params))

        let withName = makeHead([
            ("MCP-Protocol-Version", "2026-07-28"),
            ("Mcp-Method", "prompts/get"),
            ("Mcp-Name", "explain_query")
        ])
        #expect(MCPHttpHeaderValidator.validate(head: withName, message: message) == nil)

        let withoutName = makeHead([
            ("MCP-Protocol-Version", "2026-07-28"),
            ("Mcp-Method", "prompts/get")
        ])
        #expect(MCPHttpHeaderValidator.validate(head: withoutName, message: message)?.code
            == JsonRpcErrorCode.headerMismatch)
    }

    @Test("Boolean parameters compare against the lowercase spelling")
    func booleanParameters() {
        let matching = makeHead([
            ("MCP-Protocol-Version", "2026-07-28"),
            ("Mcp-Method", "tools/call"),
            ("Mcp-Name", "run_query"),
            ("Mcp-Param-Dry", "true")
        ])
        #expect(MCPHttpHeaderValidator.validate(head: matching, message: toolCall()) == nil)

        let wrongCase = makeHead([
            ("MCP-Protocol-Version", "2026-07-28"),
            ("Mcp-Method", "tools/call"),
            ("Mcp-Name", "run_query"),
            ("Mcp-Param-Dry", "True")
        ])
        #expect(MCPHttpHeaderValidator.validate(head: wrongCase, message: toolCall())?.code
            == JsonRpcErrorCode.headerMismatch)
    }

    @Test("A negative integer parameter compares numerically")
    func negativeIntegerParameter() {
        let message = JsonRpcMessage.request(JsonRpcRequest(
            id: .number(13),
            method: "tools/call",
            params: .object([
                "name": .string("run_query"),
                "arguments": .object(["offset": .int(-7)]),
                "_meta": modernMeta()
            ])
        ))
        let head = makeHead([
            ("MCP-Protocol-Version", "2026-07-28"),
            ("Mcp-Method", "tools/call"),
            ("Mcp-Name", "run_query"),
            ("Mcp-Param-Offset", "-7")
        ])
        #expect(MCPHttpHeaderValidator.validate(head: head, message: message) == nil)
    }

    @Test("A nested argument reachable through properties is matched")
    func nestedArgumentParameter() {
        let message = JsonRpcMessage.request(JsonRpcRequest(
            id: .number(14),
            method: "tools/call",
            params: .object([
                "name": .string("run_query"),
                "arguments": .object(["target": .object(["region": .string("eu-west1")])]),
                "_meta": modernMeta()
            ])
        ))
        let head = makeHead([
            ("MCP-Protocol-Version", "2026-07-28"),
            ("Mcp-Method", "tools/call"),
            ("Mcp-Name", "run_query"),
            ("Mcp-Param-Region", "eu-west1")
        ])
        #expect(MCPHttpHeaderValidator.validate(head: head, message: message) == nil)
    }

    @Test("Arguments the client never mirrored need no header")
    func unmirroredArgumentsAreFine() {
        let head = makeHead([
            ("MCP-Protocol-Version", "2026-07-28"),
            ("Mcp-Method", "tools/call"),
            ("Mcp-Name", "run_query")
        ])
        #expect(MCPHttpHeaderValidator.validate(head: head, message: toolCall()) == nil)
    }

    @Test("A parameter header value outside visible ASCII is malformed")
    func nonAsciiParameterValue() {
        let head = makeHead([
            ("MCP-Protocol-Version", "2026-07-28"),
            ("Mcp-Method", "tools/call"),
            ("Mcp-Name", "run_query"),
            ("Mcp-Param-Region", "eu-wést1")
        ])
        #expect(MCPHttpHeaderValidator.validate(head: head, message: toolCall())?.code
            == JsonRpcErrorCode.headerMismatch)
    }

    @Test("A parameter header name that is not a field token is refused")
    func invalidParameterHeaderName() {
        for name in ["Mcp-Param-", "Mcp-Param-re gion", "Mcp-Param-re@gion"] {
            let head = makeHead([
                ("MCP-Protocol-Version", "2026-07-28"),
                ("Mcp-Method", "tools/call"),
                ("Mcp-Name", "run_query"),
                (name, "us-west1")
            ])
            #expect(
                MCPHttpHeaderValidator.validate(head: head, message: toolCall())?.code
                    == JsonRpcErrorCode.headerMismatch,
                "'\(name)' is not a valid parameter header name"
            )
        }
    }

    @Test("A Base64 payload that is not valid UTF-8 is malformed")
    func undecodableSentinelValue() {
        let payload = Data([0xFF, 0xFE]).base64EncodedString()
        let head = makeHead([
            ("MCP-Protocol-Version", "2026-07-28"),
            ("Mcp-Method", "tools/call"),
            ("Mcp-Name", "=?base64?\(payload)?=")
        ])
        #expect(MCPHttpHeaderValidator.validate(head: head, message: toolCall())?.code
            == JsonRpcErrorCode.headerMismatch)
    }

    @Test("A body without the protocol version cannot satisfy the header")
    func bodyWithoutProtocolVersion() {
        let message = JsonRpcMessage.request(JsonRpcRequest(id: .number(15), method: "tools/list", params: nil))
        let head = makeHead([
            ("MCP-Protocol-Version", "2026-07-28"),
            ("Mcp-Method", "tools/list")
        ])
        #expect(MCPHttpHeaderValidator.validate(head: head, message: message)?.code
            == JsonRpcErrorCode.headerMismatch)
    }

    @Test("Notifications are validated against their headers too")
    func notificationsAreValidated() {
        let notification = JsonRpcMessage.notification(JsonRpcNotification(
            method: "notifications/progress",
            params: .object(["_meta": modernMeta()])
        ))
        let matching = makeHead([
            ("MCP-Protocol-Version", "2026-07-28"),
            ("Mcp-Method", "notifications/progress")
        ])
        #expect(MCPHttpHeaderValidator.validate(head: matching, message: notification) == nil)

        let mismatched = makeHead([
            ("MCP-Protocol-Version", "2026-07-28"),
            ("Mcp-Method", "notifications/cancelled")
        ])
        #expect(MCPHttpHeaderValidator.validate(head: mismatched, message: notification)?.code
            == JsonRpcErrorCode.headerMismatch)
    }

    @Test("Responses carry no method, so there is nothing to validate")
    func responsesAreNotValidated() {
        let response = JsonRpcMessage.successResponse(
            JsonRpcSuccessResponse(id: .number(16), result: .object([:]))
        )
        #expect(MCPHttpHeaderValidator.validate(head: makeHead([]), message: response) == nil)
    }

    @Test("Every header mismatch carries HTTP 400 and the spec code")
    func everyFailureIsBadRequest() {
        let heads = [
            makeHead([]),
            makeHead([("MCP-Protocol-Version", "2026-07-28")]),
            makeHead([("MCP-Protocol-Version", "2025-06-18"), ("Mcp-Method", "tools/call")])
        ]
        for head in heads {
            let failure = MCPHttpHeaderValidator.validate(head: head, message: toolCall())
            #expect(failure?.httpStatus == .badRequest)
            #expect(failure?.code == JsonRpcErrorCode.headerMismatch)
        }
    }
}
