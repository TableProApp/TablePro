import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("ToolsCallHandler")
struct ToolsCallHandlerTests {
    @Test("The handler answers tools/call and requires the tools read scope")
    func methodAndScopes() {
        #expect(ToolsCallHandler.method == "tools/call")
        #expect(ToolsCallHandler.requiredScopes == [.toolsRead])
        #expect(ToolsCallHandler.isAvailableToLegacyClients)
    }

    @Test("Params that are not an object are invalid params")
    func nonObjectParams() async throws {
        for params in [JsonValue.string("oops"), .array([]), .int(1), .null] {
            let error = try await failure(params: params)
            #expect(error.code == JsonRpcErrorCode.invalidParams)
        }
    }

    @Test("Params without a tool name are invalid params")
    func missingToolName() async throws {
        let error = try await failure(params: .object(["arguments": .object([:])]))
        #expect(error.code == JsonRpcErrorCode.invalidParams)
    }

    @Test("A tool name that is not a string is invalid params")
    func nonStringToolName() async throws {
        let error = try await failure(params: .object(["name": .int(7)]))
        #expect(error.code == JsonRpcErrorCode.invalidParams)
    }

    @Test("An unknown tool is reported as invalid params, not as a method that does not exist")
    func unknownToolIsInvalidParams() async throws {
        let error = try await failure(params: .object([
            "name": .string("nonexistent_tool"),
            "arguments": .object([:])
        ]))
        #expect(error.code == JsonRpcErrorCode.invalidParams)
        #expect(error.code == -32_602)
        #expect(error.message.contains("nonexistent_tool"))
    }

    @Test("A tool the principal lacks the scope for is refused with a scope challenge")
    func insufficientScopeChallenge() async throws {
        let error = try await failure(
            params: .object(["name": .string("connect"), "arguments": .object([:])]),
            scopes: [.toolsRead]
        )
        #expect(error.code == JsonRpcErrorCode.forbidden)
        #expect(error.httpStatus == .forbidden)

        let challenge = try #require(header(named: "WWW-Authenticate", in: error))
        #expect(challenge.contains("error=\"insufficient_scope\""))
        #expect(challenge.contains("tools:write"))
        #expect(error.data?["requiredScopes"]?.arrayValue?.compactMap(\.stringValue) == ["tools:write"])
    }

    @Test("A cancelled request stops before the tool runs")
    func cancelledRequestStops() async throws {
        let cancellation = MCPCancellationToken()
        await cancellation.cancel(reason: .clientDisconnected)
        let context = await MCPProtocolHandlerTestSupport.makeContext(
            method: ToolsCallHandler.method,
            cancellation: cancellation
        )
        let params = JsonValue.object(["name": .string("list_connections"), "arguments": .object([:])])

        await #expect(throws: CancellationError.self) {
            _ = try await makeHandler().handle(params: params, context: context)
        }
    }

    @Test("A tool result is returned as the whole result payload")
    func toolResultShape() async throws {
        let result = try await call(name: "list_connections")
        #expect(result.kind == .complete)

        let content = try #require(result.payload["content"]?.arrayValue)
        #expect(content.first?["type"]?.stringValue == "text")
        #expect(result.payload["isError"]?.boolValue == false)
        #expect(result.payload["structuredContent"] != nil)
    }

    @Test("tools/call is not a cacheable operation and returns no cache hint")
    func toolsCallIsNotCacheable() async throws {
        let result = try await call(name: "list_connections")
        #expect(result.cacheHint == nil)
        #expect(MCPProtocolDispatcher.cacheableMethods.contains(ToolsCallHandler.method) == false)

        let value = result.asJsonValue(era: .modern, serverInfo: MCPMethodRegistry.serverInfo)
        #expect(value["ttlMs"] == nil)
        #expect(value["cacheScope"] == nil)
        #expect(value["resultType"]?.stringValue == "complete")
    }

    @Test("Missing required arguments are refused before anything is dispatched")
    func missingRequiredArgument() async throws {
        let error = try await failure(params: .object([
            "name": .string("get_table_ddl"),
            "arguments": .object(["table": .string("users")])
        ]))
        #expect(error.code == JsonRpcErrorCode.invalidParams)
    }

    @Test("A tool that rejects its arguments reports the failure in the result, not as a protocol error")
    func malformedConnectionIdIsAToolError() async throws {
        let result = try await call(
            name: "list_tables",
            arguments: .object(["connection_id": .string("not-a-uuid")])
        )
        #expect(result.kind == .complete)
        #expect(result.payload["isError"]?.boolValue == true)

        let text = result.payload["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        #expect(text.contains("connection_id"))
    }

    @Test("Arguments default to an empty object when the client omits them")
    func argumentsMayBeOmitted() async throws {
        let result = try await call(name: "list_connections", arguments: nil)
        #expect(result.payload["content"] != nil)
    }

    private func makeHandler() -> ToolsCallHandler {
        ToolsCallHandler(services: MCPProtocolHandlerTestSupport.makeToolServices())
    }

    private func call(
        name: String,
        arguments: JsonValue? = .object([:]),
        scopes: Set<MCPScope> = [.toolsRead, .toolsWrite]
    ) async throws -> MCPResult {
        var fields: [String: JsonValue] = ["name": .string(name)]
        if let arguments {
            fields["arguments"] = arguments
        }
        let params = JsonValue.object(fields)
        let context = await MCPProtocolHandlerTestSupport.makeContext(
            method: ToolsCallHandler.method,
            params: params,
            principalScopes: scopes
        )
        return try await makeHandler().handle(params: params, context: context)
    }

    private func failure(
        params: JsonValue?,
        scopes: Set<MCPScope> = [.toolsRead, .toolsWrite]
    ) async throws -> MCPProtocolError {
        let context = await MCPProtocolHandlerTestSupport.makeContext(
            method: ToolsCallHandler.method,
            params: params,
            principalScopes: scopes
        )
        do {
            _ = try await makeHandler().handle(params: params, context: context)
        } catch let error as MCPProtocolError {
            return error
        }
        Issue.record("expected the handler to refuse the request")
        return .internalError(detail: "unreachable")
    }

    private func header(named name: String, in error: MCPProtocolError) -> String? {
        error.extraHeaders.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }
}
