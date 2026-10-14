import Foundation
@testable import TablePro
import TableProMCP
import TableProPluginKit
import Testing

struct ResourcesListHandlerTests {
    @Test
    func methodIsResourcesList() {
        #expect(ResourcesListHandler.method == "resources/list")
    }

    @Test
    func requiresResourcesReadScope() {
        #expect(ResourcesListHandler.requiredScopes == [.resourcesRead])
    }

    @Test
    func isOfferedToLegacyClients() {
        #expect(ResourcesListHandler.isAvailableToLegacyClients)
    }

    @Test
    func listsTheSavedConnectionsResource() async throws {
        let result = try await runList()
        let resources = try #require(result.payload["resources"]?.arrayValue)
        let uris = resources.compactMap { $0["uri"]?.stringValue }
        #expect(uris.contains("tablepro://connections"))
    }

    @Test
    func everyEntryDescribesItself() async throws {
        let result = try await runList()
        let resources = try #require(result.payload["resources"]?.arrayValue)
        #expect(!resources.isEmpty)

        for resource in resources {
            #expect(!(resource["uri"]?.stringValue?.isEmpty ?? true))
            #expect(!(resource["name"]?.stringValue?.isEmpty ?? true))
            #expect(!(resource["title"]?.stringValue?.isEmpty ?? true))
            #expect(!(resource["description"]?.stringValue?.isEmpty ?? true))
            #expect(resource["mimeType"]?.stringValue == "application/json")
        }
    }

    @Test
    func resultIsCompleteAndCacheableForThisPrincipalOnly() async throws {
        let result = try await runList()
        #expect(result.kind == .complete)

        let hint = try #require(result.cacheHint)
        #expect(hint.scope == .privateScope)
        #expect(hint.ttlMilliseconds == 30_000)
        #expect(MCPProtocolDispatcher.cacheableMethods.contains(ResourcesListHandler.method))
    }

    @Test
    func shortListingCarriesNoCursor() async throws {
        let result = try await runList()
        let count = result.payload["resources"]?.arrayValue?.count ?? 0
        #expect(count <= MCPListPagination.defaultPageSize)
        #expect(result.payload["nextCursor"] == nil)
    }

    @Test
    func emptyCursorIsRefused() async throws {
        let error = try await failure(params: .object(["cursor": .string("")]))
        #expect(error.code == JsonRpcErrorCode.invalidParams)
    }

    @Test
    func cursorFromAnotherMethodIsRefused() async throws {
        let cursor = MCPListPagination.encodeCursor(offset: 0, method: "tools/list")
        let error = try await failure(params: .object(["cursor": .string(cursor)]))
        #expect(error.code == JsonRpcErrorCode.invalidParams)
    }

    @Test
    func cursorPastTheEndIsRefused() async throws {
        let cursor = MCPListPagination.encodeCursor(offset: 9_999, method: ResourcesListHandler.method)
        let error = try await failure(params: .object(["cursor": .string(cursor)]))
        #expect(error.code == JsonRpcErrorCode.invalidParams)
    }

    private func runList(params: JsonValue? = nil) async throws -> MCPResult {
        let services = MCPProtocolHandlerTestSupport.makeToolServices()
        let context = await MCPProtocolHandlerTestSupport.makeContext(
            method: ResourcesListHandler.method,
            params: params,
            principalScopes: [.resourcesRead]
        )
        return try await ResourcesListHandler(services: services).handle(params: params, context: context)
    }

    private func failure(params: JsonValue?) async throws -> MCPProtocolError {
        do {
            _ = try await runList(params: params)
        } catch let error as MCPProtocolError {
            return error
        }
        Issue.record("Expected the handler to refuse the request")
        return .internalError(detail: "unreachable")
    }
}
