import Foundation
@testable import TablePro
import TableProMCP
import TableProPluginKit
import Testing

struct PromptsListHandlerTests {
    @Test
    func methodIsPromptsList() {
        #expect(PromptsListHandler.method == "prompts/list")
    }

    @Test
    func requiresResourcesReadScope() {
        #expect(PromptsListHandler.requiredScopes == [.resourcesRead])
    }

    @Test
    func isAvailableToLegacyClients() {
        #expect(PromptsListHandler.isAvailableToLegacyClients)
    }

    @Test
    func returnsTheWholeCatalogRatherThanAnEmptyList() async throws {
        let result = try await list(params: nil)
        let prompts = try #require(result.payload["prompts"]?.arrayValue)

        #expect(!prompts.isEmpty, "prompts/list is advertised, so it must return the catalog")
        #expect(prompts.count == MCPPromptCatalog.all.count)

        let names = prompts.compactMap { $0["name"]?.stringValue }
        #expect(names == MCPPromptCatalog.all.map(\.name))
    }

    @Test
    func everyListedPromptCarriesItsTitleAndDescription() async throws {
        let result = try await list(params: nil)
        let prompts = try #require(result.payload["prompts"]?.arrayValue)

        for prompt in prompts {
            #expect(prompt["name"]?.stringValue != nil)
            #expect(prompt["title"]?.stringValue?.isEmpty == false)
            #expect(prompt["description"]?.stringValue?.isEmpty == false)
        }
    }

    @Test
    func resultIsPubliclyCacheableForAnHour() async throws {
        let result = try await list(params: nil)
        let hint = try #require(result.cacheHint)

        #expect(hint.scope == .publicScope)
        #expect(hint.ttlMilliseconds == 3_600_000)
    }

    @Test
    func modernSerialisationCarriesTheCacheFields() async throws {
        let result = try await list(params: nil)
        let json = result.asJsonValue(era: .modern, serverInfo: nil)

        #expect(json["resultType"]?.stringValue == "complete")
        #expect(json["ttlMs"]?.intValue == 3_600_000)
        #expect(json["cacheScope"]?.stringValue == "public")
    }

    @Test
    func legacySerialisationOmitsTheCacheFields() async throws {
        let result = try await list(params: nil)
        let json = result.asJsonValue(era: .legacy, serverInfo: nil)

        #expect(json["resultType"] == nil)
        #expect(json["ttlMs"] == nil)
        #expect(json["cacheScope"] == nil)
        #expect(json["prompts"] != nil)
    }

    @Test
    func aSinglePageNeedsNoCursor() async throws {
        let result = try await list(params: nil)
        #expect(result.payload["nextCursor"] == nil)
    }

    @Test
    func aCursorForThisMethodResumesTheCatalog() async throws {
        let cursor = MCPListPagination.encodeCursor(offset: 1, method: PromptsListHandler.method)
        let result = try await list(params: .object(["cursor": .string(cursor)]))
        let names = result.payload["prompts"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []

        #expect(names == Array(MCPPromptCatalog.all.map(\.name).dropFirst()))
    }

    @Test
    func aCursorMintedForAnotherMethodIsRefused() async throws {
        let cursor = MCPListPagination.encodeCursor(offset: 0, method: "tools/list")
        let error = try await failure(params: .object(["cursor": .string(cursor)]))
        #expect(error.code == JsonRpcErrorCode.invalidParams)
    }

    @Test
    func aGarbageCursorIsRefused() async throws {
        let error = try await failure(params: .object(["cursor": .string("not-a-cursor")]))
        #expect(error.code == JsonRpcErrorCode.invalidParams)
    }

    @Test
    func aNonStringCursorIsRefused() async throws {
        let error = try await failure(params: .object(["cursor": .int(3)]))
        #expect(error.code == JsonRpcErrorCode.invalidParams)
    }

    @Test
    func aCursorPastTheEndIsRefused() async throws {
        let cursor = MCPListPagination.encodeCursor(
            offset: MCPPromptCatalog.all.count + 1,
            method: PromptsListHandler.method
        )
        let error = try await failure(params: .object(["cursor": .string(cursor)]))
        #expect(error.code == JsonRpcErrorCode.invalidParams)
    }

    @Test
    func aShortPageHandsBackACursorThatResumesWhereItStopped() throws {
        let names = MCPPromptCatalog.all.map(\.name)
        let firstPage = try MCPListPagination.page(
            names,
            cursor: nil,
            method: PromptsListHandler.method,
            pageSize: 2
        )
        #expect(firstPage.items == Array(names.prefix(2)))
        let cursor = try #require(firstPage.nextCursor)

        let secondPage = try MCPListPagination.page(
            names,
            cursor: cursor,
            method: PromptsListHandler.method,
            pageSize: 2
        )
        #expect(secondPage.items == Array(names.dropFirst(2).prefix(2)))
    }

    private func list(params: JsonValue?) async throws -> MCPResult {
        let context = await MCPProtocolHandlerTestSupport.makeContext(
            method: PromptsListHandler.method,
            params: params,
            principalScopes: MCPScope.readOnlySet
        )
        return try await PromptsListHandler().handle(params: params, context: context)
    }

    private func failure(params: JsonValue?) async throws -> MCPProtocolError {
        do {
            let result = try await list(params: params)
            Issue.record("Expected an MCPProtocolError, got \(result)")
            throw PromptsListTestError.unexpectedSuccess
        } catch let error as MCPProtocolError {
            return error
        }
    }
}

private enum PromptsListTestError: Error {
    case unexpectedSuccess
}
