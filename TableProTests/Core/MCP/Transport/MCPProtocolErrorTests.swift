import Foundation
import TableProPluginKit
@testable import TablePro
import XCTest

final class MCPProtocolErrorTests: XCTestCase {
    func testSessionNotFoundMapping() {
        let error = MCPProtocolError.sessionNotFound()
        XCTAssertEqual(error.code, JsonRpcErrorCode.sessionNotFound)
        XCTAssertEqual(error.httpStatus, .notFound)
    }

    func testMissingSessionIdMapping() {
        let error = MCPProtocolError.missingSessionId()
        XCTAssertEqual(error.code, JsonRpcErrorCode.invalidRequest)
        XCTAssertEqual(error.httpStatus, .badRequest)
    }

    func testParseErrorMapping() {
        let error = MCPProtocolError.parseError(detail: "bad json")
        XCTAssertEqual(error.code, JsonRpcErrorCode.parseError)
        XCTAssertEqual(error.httpStatus, .badRequest)
        XCTAssertTrue(error.message.contains("bad json"))
    }

    func testInvalidRequestMapping() {
        let error = MCPProtocolError.invalidRequest(detail: "missing method")
        XCTAssertEqual(error.code, JsonRpcErrorCode.invalidRequest)
        XCTAssertEqual(error.httpStatus, .badRequest)
    }

    func testMethodNotFoundIsHttp200() {
        let error = MCPProtocolError.methodNotFound(method: "tools/foo")
        XCTAssertEqual(error.code, JsonRpcErrorCode.methodNotFound)
        XCTAssertEqual(error.httpStatus, .ok)
    }

    func testInvalidParamsIsHttp200() {
        let error = MCPProtocolError.invalidParams(detail: "expected object")
        XCTAssertEqual(error.code, JsonRpcErrorCode.invalidParams)
        XCTAssertEqual(error.httpStatus, .ok)
    }

    func testInternalErrorMapping() {
        let error = MCPProtocolError.internalError(detail: "boom")
        XCTAssertEqual(error.code, JsonRpcErrorCode.internalError)
        XCTAssertEqual(error.httpStatus, .internalServerError)
    }

    func testUnauthenticatedIncludesWwwAuthenticate() {
        let error = MCPProtocolError.unauthenticated(challenge: "Bearer realm=\"x\"")
        XCTAssertEqual(error.code, JsonRpcErrorCode.unauthenticated)
        XCTAssertEqual(error.httpStatus, .unauthorized)
        let header = error.extraHeaders.first { $0.0.lowercased() == "www-authenticate" }
        XCTAssertNotNil(header)
        XCTAssertEqual(header?.1, "Bearer realm=\"x\"")
    }

    func testTokenInvalidIncludesWwwAuthenticate() {
        let error = MCPProtocolError.tokenInvalid()
        XCTAssertEqual(error.httpStatus, .unauthorized)
        XCTAssertTrue(error.extraHeaders.contains { $0.0.lowercased() == "www-authenticate" })
    }

    func testTokenExpiredIncludesWwwAuthenticate() {
        let error = MCPProtocolError.tokenExpired()
        XCTAssertEqual(error.httpStatus, .unauthorized)
        XCTAssertTrue(error.extraHeaders.contains { $0.0.lowercased() == "www-authenticate" })
    }

    func testForbiddenMapping() {
        let error = MCPProtocolError.forbidden(reason: "policy")
        XCTAssertEqual(error.code, JsonRpcErrorCode.forbidden)
        XCTAssertEqual(error.httpStatus, .forbidden)
    }

    func testRateLimitedMapping() {
        let error = MCPProtocolError.rateLimited()
        XCTAssertEqual(error.httpStatus, .tooManyRequests)
    }

    func testPayloadTooLargeMapping() {
        let error = MCPProtocolError.payloadTooLarge()
        XCTAssertEqual(error.code, JsonRpcErrorCode.tooLarge)
        XCTAssertEqual(error.httpStatus, .payloadTooLarge)
    }

    func testNotAcceptableMapping() {
        let error = MCPProtocolError.notAcceptable()
        XCTAssertEqual(error.httpStatus, .notAcceptable)
    }

    func testUnsupportedMediaTypeMapping() {
        let error = MCPProtocolError.unsupportedMediaType()
        XCTAssertEqual(error.httpStatus, .unsupportedMediaType)
    }

    func testServiceUnavailableMapping() {
        let error = MCPProtocolError.serviceUnavailable()
        XCTAssertEqual(error.httpStatus, .serviceUnavailable)
    }

    func testToJsonRpcErrorResponseRoundTrip() {
        let protocolError = MCPProtocolError.sessionNotFound()
        let response = protocolError.toJsonRpcErrorResponse(id: .number(7))
        XCTAssertEqual(response.id, .number(7))
        XCTAssertEqual(response.error.code, JsonRpcErrorCode.sessionNotFound)
        XCTAssertEqual(response.error.message, "Session not found")
    }

    func testToJsonRpcErrorResponseWithNilId() {
        let protocolError = MCPProtocolError.parseError(detail: "x")
        let response = protocolError.toJsonRpcErrorResponse(id: nil)
        XCTAssertNil(response.id)
        XCTAssertEqual(response.error.code, JsonRpcErrorCode.parseError)
    }

    func testEqualityIgnoresHeadersAndStatus() {
        let lhs = MCPProtocolError(code: -1, message: "x", httpStatus: .ok)
        let rhs = MCPProtocolError(
            code: -1,
            message: "x",
            httpStatus: .badRequest,
            extraHeaders: [("X", "Y")]
        )
        XCTAssertEqual(lhs, rhs)
    }
}
