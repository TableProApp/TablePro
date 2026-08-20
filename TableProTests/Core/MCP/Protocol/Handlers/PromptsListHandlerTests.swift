import Foundation
import TableProPluginKit
@testable import TablePro
import XCTest

final class PromptsListHandlerTests: XCTestCase {
    func testMethodIsPromptsList() {
        XCTAssertEqual(PromptsListHandler.method, "prompts/list")
    }

    func testRequiresResourcesReadScope() {
        XCTAssertEqual(PromptsListHandler.requiredScopes, [.resourcesRead])
    }

    func testIsAvailableToLegacyClients() {
        XCTAssertTrue(PromptsListHandler.isAvailableToLegacyClients)
    }

    func testReturnsTheWholeCatalogRatherThanAnEmptyList() async throws {
        let result = try await list(params: nil)
        let prompts = try XCTUnwrap(result.payload["prompts"]?.arrayValue)

        XCTAssertFalse(prompts.isEmpty, "prompts/list is advertised, so it must return the catalog")
        XCTAssertEqual(prompts.count, MCPPromptCatalog.all.count)

        let names = prompts.compactMap { $0["name"]?.stringValue }
        XCTAssertEqual(names, MCPPromptCatalog.all.map(\.name))
    }

    func testEveryListedPromptCarriesItsTitleAndDescription() async throws {
        let result = try await list(params: nil)
        let prompts = try XCTUnwrap(result.payload["prompts"]?.arrayValue)

        for prompt in prompts {
            XCTAssertNotNil(prompt["name"]?.stringValue)
            XCTAssertEqual(prompt["title"]?.stringValue?.isEmpty, false)
            XCTAssertEqual(prompt["description"]?.stringValue?.isEmpty, false)
        }
    }

    func testResultIsPubliclyCacheableForAnHour() async throws {
        let result = try await list(params: nil)
        let hint = try XCTUnwrap(result.cacheHint)

        XCTAssertEqual(hint.scope, .publicScope)
        XCTAssertEqual(hint.ttlMilliseconds, 3_600_000)
    }

    func testModernSerialisationCarriesTheCacheFields() async throws {
        let result = try await list(params: nil)
        let json = result.asJsonValue(era: .modern, serverInfo: nil)

        XCTAssertEqual(json["resultType"]?.stringValue, "complete")
        XCTAssertEqual(json["ttlMs"]?.intValue, 3_600_000)
        XCTAssertEqual(json["cacheScope"]?.stringValue, "public")
    }

    func testLegacySerialisationOmitsTheCacheFields() async throws {
        let result = try await list(params: nil)
        let json = result.asJsonValue(era: .legacy, serverInfo: nil)

        XCTAssertNil(json["resultType"])
        XCTAssertNil(json["ttlMs"])
        XCTAssertNil(json["cacheScope"])
        XCTAssertNotNil(json["prompts"])
    }

    func testASinglePageNeedsNoCursor() async throws {
        let result = try await list(params: nil)
        XCTAssertNil(result.payload["nextCursor"])
    }

    func testACursorForThisMethodResumesTheCatalog() async throws {
        let cursor = MCPListPagination.encodeCursor(offset: 1, method: PromptsListHandler.method)
        let result = try await list(params: .object(["cursor": .string(cursor)]))
        let names = result.payload["prompts"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []

        XCTAssertEqual(names, Array(MCPPromptCatalog.all.map(\.name).dropFirst()))
    }

    func testACursorMintedForAnotherMethodIsRefused() async throws {
        let cursor = MCPListPagination.encodeCursor(offset: 0, method: "tools/list")
        let error = try await failure(params: .object(["cursor": .string(cursor)]))
        XCTAssertEqual(error.code, JsonRpcErrorCode.invalidParams)
    }

    func testAGarbageCursorIsRefused() async throws {
        let error = try await failure(params: .object(["cursor": .string("not-a-cursor")]))
        XCTAssertEqual(error.code, JsonRpcErrorCode.invalidParams)
    }

    func testANonStringCursorIsRefused() async throws {
        let error = try await failure(params: .object(["cursor": .int(3)]))
        XCTAssertEqual(error.code, JsonRpcErrorCode.invalidParams)
    }

    func testACursorPastTheEndIsRefused() async throws {
        let cursor = MCPListPagination.encodeCursor(
            offset: MCPPromptCatalog.all.count + 1,
            method: PromptsListHandler.method
        )
        let error = try await failure(params: .object(["cursor": .string(cursor)]))
        XCTAssertEqual(error.code, JsonRpcErrorCode.invalidParams)
    }

    func testAShortPageHandsBackACursorThatResumesWhereItStopped() throws {
        let names = MCPPromptCatalog.all.map(\.name)
        let firstPage = try MCPListPagination.page(
            names,
            cursor: nil,
            method: PromptsListHandler.method,
            pageSize: 2
        )
        XCTAssertEqual(firstPage.items, Array(names.prefix(2)))
        let cursor = try XCTUnwrap(firstPage.nextCursor)

        let secondPage = try MCPListPagination.page(
            names,
            cursor: cursor,
            method: PromptsListHandler.method,
            pageSize: 2
        )
        XCTAssertEqual(secondPage.items, Array(names.dropFirst(2).prefix(2)))
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
            XCTFail("Expected an MCPProtocolError, got \(result)")
            throw PromptsListTestError.unexpectedSuccess
        } catch let error as MCPProtocolError {
            return error
        }
    }
}

private enum PromptsListTestError: Error {
    case unexpectedSuccess
}
