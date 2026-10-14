import Foundation
@testable import TablePro
import TableProMCP
import TableProPluginKit
import Testing

struct ResourcesReadHandlerTests {
    @Test
    func methodIsResourcesRead() {
        #expect(ResourcesReadHandler.method == "resources/read")
    }

    @Test
    func requiresResourcesReadScope() {
        #expect(ResourcesReadHandler.requiredScopes == [.resourcesRead])
    }

    @Test
    func readsTheConnectionsResource() async throws {
        let result = try await read(uri: "tablepro://connections")
        #expect(result.kind == .complete)

        let contents = try #require(result.payload["contents"]?.arrayValue)
        #expect(contents.count == 1)

        let entry = try #require(contents.first)
        #expect(entry["uri"]?.stringValue == "tablepro://connections")
        #expect(entry["mimeType"]?.stringValue == "application/json")

        let text = try #require(entry["text"]?.stringValue)
        let decoded = try JSONDecoder().decode(JsonValue.self, from: Data(text.utf8))
        #expect(decoded["connections"]?.arrayValue != nil)
    }

    @Test
    func readIsCacheableForThisPrincipalOnly() async throws {
        let result = try await read(uri: "tablepro://connections")
        let hint = try #require(result.cacheHint)
        #expect(hint.scope == .privateScope)
        #expect(hint.ttlMilliseconds == 15_000)
        #expect(MCPProtocolDispatcher.cacheableMethods.contains(ResourcesReadHandler.method))
    }

    @Test
    func missingUriIsInvalidParams() async throws {
        let error = try await failure(params: .object([:]))
        #expect(error.code == JsonRpcErrorCode.invalidParams)
        #expect(error.httpStatus == .badRequest)
    }

    @Test
    func uriThatIsNotAStringIsInvalidParams() async throws {
        let error = try await failure(params: .object(["uri": .int(7)]))
        #expect(error.code == JsonRpcErrorCode.invalidParams)
    }

    @Test
    func nonTableproSchemeIsInvalidParams() async throws {
        let error = try await failure(params: .object(["uri": .string("https://example.com/foo")]))
        #expect(error.code == JsonRpcErrorCode.invalidParams)
    }

    @Test
    func unknownResourceIsInvalidParamsNotResourceNotFound() async throws {
        let error = try await failure(params: .object(["uri": .string("tablepro://unknown/resource")]))
        #expect(error.code == JsonRpcErrorCode.invalidParams)
        #expect(error.code == -32_602)
        #expect(error.code != JsonRpcErrorCode.methodNotFound)
        #expect(error.code != -32_002)
    }

    @Test
    func connectionIdThatIsNotAUuidIsInvalidParams() async throws {
        let error = try await failure(params: .object(["uri": .string("tablepro://connections/not-a-uuid/schema")]))
        #expect(error.code == JsonRpcErrorCode.invalidParams)
    }

    @Test
    func unknownConnectionSubresourceIsInvalidParams() async throws {
        let uri = "tablepro://connections/\(UUID().uuidString)/bogus"
        let error = try await failure(params: .object(["uri": .string(uri)]))
        #expect(error.code == JsonRpcErrorCode.invalidParams)
    }

    @Test
    func unknownTableSubresourceIsInvalidParams() async throws {
        let uri = "tablepro://connections/\(UUID().uuidString)/tables/users/statistics"
        let error = try await failure(params: .object(["uri": .string(uri)]))
        #expect(error.code == JsonRpcErrorCode.invalidParams)
    }

    @Test
    func cancelledRequestStopsBeforeReading() async throws {
        let cancellation = MCPCancellationToken()
        await cancellation.cancel(reason: .clientDisconnected)
        let services = MCPProtocolHandlerTestSupport.makeToolServices()
        let context = await MCPProtocolHandlerTestSupport.makeContext(
            method: ResourcesReadHandler.method,
            principalScopes: [.resourcesRead],
            cancellation: cancellation
        )

        do {
            _ = try await ResourcesReadHandler(services: services).handle(
                params: .object(["uri": .string("tablepro://connections")]),
                context: context
            )
            Issue.record("Expected the read to stop")
        } catch is CancellationError {
            return
        }
    }

    private func read(uri: String) async throws -> MCPResult {
        try await run(params: .object(["uri": .string(uri)]))
    }

    private func run(params: JsonValue?) async throws -> MCPResult {
        let services = MCPProtocolHandlerTestSupport.makeToolServices()
        let context = await MCPProtocolHandlerTestSupport.makeContext(
            method: ResourcesReadHandler.method,
            params: params,
            principalScopes: [.resourcesRead]
        )
        return try await ResourcesReadHandler(services: services).handle(params: params, context: context)
    }

    private func failure(params: JsonValue?) async throws -> MCPProtocolError {
        do {
            _ = try await run(params: params)
        } catch let error as MCPProtocolError {
            return error
        }
        Issue.record("Expected the handler to refuse the request")
        return .internalError(detail: "unreachable")
    }
}
