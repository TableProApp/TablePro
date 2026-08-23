import Foundation
import TableProPluginKit
@testable import TablePro
import XCTest

final class ResourcesListHandlerTests: XCTestCase {
    func testMethodIsResourcesList() {
        XCTAssertEqual(ResourcesListHandler.method, "resources/list")
    }

    func testRequiresResourcesReadScope() {
        XCTAssertEqual(ResourcesListHandler.requiredScopes, [.resourcesRead])
    }

    func testIsOfferedToLegacyClients() {
        XCTAssertTrue(ResourcesListHandler.isAvailableToLegacyClients)
    }

    func testListsTheSavedConnectionsResource() async throws {
        let result = try await runList()
        let resources = try XCTUnwrap(result.payload["resources"]?.arrayValue)
        let uris = resources.compactMap { $0["uri"]?.stringValue }
        XCTAssertTrue(uris.contains("tablepro://connections"))
    }

    func testEveryEntryDescribesItself() async throws {
        let result = try await runList()
        let resources = try XCTUnwrap(result.payload["resources"]?.arrayValue)
        XCTAssertFalse(resources.isEmpty)

        for resource in resources {
            XCTAssertFalse(resource["uri"]?.stringValue?.isEmpty ?? true)
            XCTAssertFalse(resource["name"]?.stringValue?.isEmpty ?? true)
            XCTAssertFalse(resource["title"]?.stringValue?.isEmpty ?? true)
            XCTAssertFalse(resource["description"]?.stringValue?.isEmpty ?? true)
            XCTAssertEqual(resource["mimeType"]?.stringValue, "application/json")
        }
    }

    func testResultIsCompleteAndCacheableForThisPrincipalOnly() async throws {
        let result = try await runList()
        XCTAssertEqual(result.kind, .complete)

        let hint = try XCTUnwrap(result.cacheHint)
        XCTAssertEqual(hint.scope, .privateScope)
        XCTAssertEqual(hint.ttlMilliseconds, 30_000)
        XCTAssertTrue(MCPProtocolDispatcher.cacheableMethods.contains(ResourcesListHandler.method))
    }

    func testShortListingCarriesNoCursor() async throws {
        let result = try await runList()
        let count = result.payload["resources"]?.arrayValue?.count ?? 0
        XCTAssertLessThanOrEqual(count, MCPListPagination.defaultPageSize)
        XCTAssertNil(result.payload["nextCursor"])
    }

    func testEmptyCursorIsRefused() async throws {
        let error = try await failure(params: .object(["cursor": .string("")]))
        XCTAssertEqual(error.code, JsonRpcErrorCode.invalidParams)
    }

    func testCursorFromAnotherMethodIsRefused() async throws {
        let cursor = MCPListPagination.encodeCursor(offset: 0, method: "tools/list")
        let error = try await failure(params: .object(["cursor": .string(cursor)]))
        XCTAssertEqual(error.code, JsonRpcErrorCode.invalidParams)
    }

    func testCursorPastTheEndIsRefused() async throws {
        let cursor = MCPListPagination.encodeCursor(offset: 9_999, method: ResourcesListHandler.method)
        let error = try await failure(params: .object(["cursor": .string(cursor)]))
        XCTAssertEqual(error.code, JsonRpcErrorCode.invalidParams)
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
        XCTFail("Expected the handler to refuse the request")
        return .internalError(detail: "unreachable")
    }
}
