import Foundation
import TableProPluginKit
@testable import TablePro
import XCTest

final class ResourcesReadHandlerTests: XCTestCase {
    func testMethodIsResourcesRead() {
        XCTAssertEqual(ResourcesReadHandler.method, "resources/read")
    }

    func testRequiresResourcesReadScope() {
        XCTAssertEqual(ResourcesReadHandler.requiredScopes, [.resourcesRead])
    }

    func testReadsTheConnectionsResource() async throws {
        let result = try await read(uri: "tablepro://connections")
        XCTAssertEqual(result.kind, .complete)

        let contents = try XCTUnwrap(result.payload["contents"]?.arrayValue)
        XCTAssertEqual(contents.count, 1)

        let entry = try XCTUnwrap(contents.first)
        XCTAssertEqual(entry["uri"]?.stringValue, "tablepro://connections")
        XCTAssertEqual(entry["mimeType"]?.stringValue, "application/json")

        let text = try XCTUnwrap(entry["text"]?.stringValue)
        let decoded = try JSONDecoder().decode(JsonValue.self, from: Data(text.utf8))
        XCTAssertNotNil(decoded["connections"]?.arrayValue)
    }

    func testReadIsCacheableForThisPrincipalOnly() async throws {
        let result = try await read(uri: "tablepro://connections")
        let hint = try XCTUnwrap(result.cacheHint)
        XCTAssertEqual(hint.scope, .privateScope)
        XCTAssertEqual(hint.ttlMilliseconds, 15_000)
        XCTAssertTrue(MCPProtocolDispatcher.cacheableMethods.contains(ResourcesReadHandler.method))
    }

    func testMissingUriIsInvalidParams() async throws {
        let error = try await failure(params: .object([:]))
        XCTAssertEqual(error.code, JsonRpcErrorCode.invalidParams)
        XCTAssertEqual(error.httpStatus, .badRequest)
    }

    func testUriThatIsNotAStringIsInvalidParams() async throws {
        let error = try await failure(params: .object(["uri": .int(7)]))
        XCTAssertEqual(error.code, JsonRpcErrorCode.invalidParams)
    }

    func testNonTableproSchemeIsInvalidParams() async throws {
        let error = try await failure(params: .object(["uri": .string("https://example.com/foo")]))
        XCTAssertEqual(error.code, JsonRpcErrorCode.invalidParams)
    }

    func testUnknownResourceIsInvalidParamsNotResourceNotFound() async throws {
        let error = try await failure(params: .object(["uri": .string("tablepro://unknown/resource")]))
        XCTAssertEqual(error.code, JsonRpcErrorCode.invalidParams)
        XCTAssertEqual(error.code, -32_602)
        XCTAssertNotEqual(error.code, JsonRpcErrorCode.methodNotFound)
        XCTAssertNotEqual(error.code, -32_002)
    }

    func testConnectionIdThatIsNotAUuidIsInvalidParams() async throws {
        let error = try await failure(params: .object(["uri": .string("tablepro://connections/not-a-uuid/schema")]))
        XCTAssertEqual(error.code, JsonRpcErrorCode.invalidParams)
    }

    func testUnknownConnectionSubresourceIsInvalidParams() async throws {
        let uri = "tablepro://connections/\(UUID().uuidString)/bogus"
        let error = try await failure(params: .object(["uri": .string(uri)]))
        XCTAssertEqual(error.code, JsonRpcErrorCode.invalidParams)
    }

    func testUnknownTableSubresourceIsInvalidParams() async throws {
        let uri = "tablepro://connections/\(UUID().uuidString)/tables/users/statistics"
        let error = try await failure(params: .object(["uri": .string(uri)]))
        XCTAssertEqual(error.code, JsonRpcErrorCode.invalidParams)
    }

    func testCancelledRequestStopsBeforeReading() async throws {
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
            XCTFail("Expected the read to stop")
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
        XCTFail("Expected the handler to refuse the request")
        return .internalError(detail: "unreachable")
    }
}
