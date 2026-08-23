import Foundation
import TableProPluginKit
@testable import TablePro
import XCTest

final class MCPProtocolErrorTests: XCTestCase {
    private func header(_ error: MCPProtocolError, _ name: String) -> String? {
        error.extraHeaders.first { $0.0.lowercased() == name.lowercased() }?.1
    }

    func testHeaderMismatchIsTheSpecCodeWithBadRequest() {
        let error = MCPProtocolError.headerMismatch(detail: "Mcp-Name header is required for tools/call")
        XCTAssertEqual(error.code, -32_020)
        XCTAssertEqual(error.code, JsonRpcErrorCode.headerMismatch)
        XCTAssertEqual(error.httpStatus, .badRequest)
        XCTAssertTrue(error.message.contains("Mcp-Name"))
    }

    func testMissingRequiredClientCapabilityListsTheCapabilities() {
        let error = MCPProtocolError.missingRequiredClientCapability(["elicitation"])
        XCTAssertEqual(error.code, -32_021)
        XCTAssertEqual(error.httpStatus, .badRequest)
        XCTAssertEqual(
            error.data?["requiredCapabilities"]?.arrayValue?.compactMap(\.stringValue),
            ["elicitation"]
        )
    }

    func testUnsupportedProtocolVersionListsTheSupportedVersions() {
        let error = MCPProtocolError.unsupportedProtocolVersion(requested: "2024-11-05")
        XCTAssertEqual(error.code, -32_022)
        XCTAssertEqual(error.httpStatus, .badRequest)
        XCTAssertEqual(
            error.data?["supported"]?.arrayValue?.compactMap(\.stringValue),
            MCPProtocolVersion.supportedRawValues
        )
        XCTAssertEqual(error.data?["requested"]?.stringValue, "2024-11-05")
    }

    func testUnsupportedProtocolVersionOmitsRequestedWhenUnknown() {
        let error = MCPProtocolError.unsupportedProtocolVersion(requested: nil)
        XCTAssertNil(error.data?["requested"])
        XCTAssertNotNil(error.data?["supported"])
    }

    func testMethodNotFoundCarriesHttp404() {
        let error = MCPProtocolError.methodNotFound(method: "tools/teleport")
        XCTAssertEqual(error.code, JsonRpcErrorCode.methodNotFound)
        XCTAssertEqual(error.httpStatus, .notFound)
    }

    func testNotFoundIsInvalidParams() {
        let error = MCPProtocolError.notFound(detail: "No such resource")
        XCTAssertEqual(error.code, -32_602)
        XCTAssertEqual(error.code, JsonRpcErrorCode.invalidParams)
        XCTAssertEqual(error.httpStatus, .badRequest)
        XCTAssertEqual(error.message, "No such resource")
    }

    func testInvalidParamsMapping() {
        let error = MCPProtocolError.invalidParams(detail: "expected object")
        XCTAssertEqual(error.code, JsonRpcErrorCode.invalidParams)
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

    func testInternalErrorMapping() {
        let error = MCPProtocolError.internalError(detail: "boom")
        XCTAssertEqual(error.code, JsonRpcErrorCode.internalError)
        XCTAssertEqual(error.httpStatus, .internalServerError)
    }

    func testUnauthenticatedCarriesABearerChallenge() {
        let error = MCPProtocolError.unauthenticated()
        XCTAssertEqual(error.code, JsonRpcErrorCode.unauthenticated)
        XCTAssertEqual(error.httpStatus, .unauthorized)
        XCTAssertEqual(header(error, "WWW-Authenticate"), "Bearer realm=\"TablePro\"")
    }

    func testTokenInvalidNamesTheInvalidTokenError() {
        let error = MCPProtocolError.tokenInvalid()
        XCTAssertEqual(error.httpStatus, .unauthorized)
        XCTAssertEqual(header(error, "WWW-Authenticate"), "Bearer realm=\"TablePro\", error=\"invalid_token\"")
    }

    func testTokenExpiredDescribesTheExpiry() throws {
        let error = MCPProtocolError.tokenExpired()
        XCTAssertEqual(error.code, JsonRpcErrorCode.expired)
        XCTAssertEqual(error.httpStatus, .unauthorized)
        let challenge = try XCTUnwrap(header(error, "WWW-Authenticate"))
        XCTAssertTrue(challenge.contains("error=\"invalid_token\""))
        XCTAssertTrue(challenge.contains("error_description=\"token expired\""))
    }

    func testInsufficientScopeEmitsAStructuredChallengeAndData() throws {
        let error = MCPProtocolError.insufficientScope(
            required: [.toolsWrite, .toolsRead],
            reason: "tools/call requires tools:write"
        )
        XCTAssertEqual(error.code, JsonRpcErrorCode.forbidden)
        XCTAssertEqual(error.httpStatus, .forbidden)
        let challenge = try XCTUnwrap(header(error, "WWW-Authenticate"))
        XCTAssertTrue(challenge.contains("error=\"insufficient_scope\""))
        XCTAssertTrue(challenge.contains("scope=\"tools:read tools:write\""))
        XCTAssertEqual(
            error.data?["requiredScopes"]?.arrayValue?.compactMap(\.stringValue),
            ["tools:read", "tools:write"]
        )
    }

    func testForbiddenMapping() {
        let error = MCPProtocolError.forbidden(reason: "policy")
        XCTAssertEqual(error.code, JsonRpcErrorCode.forbidden)
        XCTAssertEqual(error.httpStatus, .forbidden)
    }

    func testRateLimitedIncludesRetryAfterOnlyWhenPositive() {
        let withRetry = MCPProtocolError.rateLimited(retryAfterSeconds: 30)
        XCTAssertEqual(withRetry.code, JsonRpcErrorCode.rateLimited)
        XCTAssertEqual(withRetry.httpStatus, .tooManyRequests)
        XCTAssertEqual(header(withRetry, "Retry-After"), "30")

        XCTAssertNil(header(MCPProtocolError.rateLimited(), "Retry-After"))
        XCTAssertNil(header(MCPProtocolError.rateLimited(retryAfterSeconds: 0), "Retry-After"))
    }

    func testPayloadTooLargeMapping() {
        let error = MCPProtocolError.payloadTooLarge()
        XCTAssertEqual(error.code, JsonRpcErrorCode.tooLarge)
        XCTAssertEqual(error.httpStatus, .payloadTooLarge)
    }

    func testNotAcceptableMapping() {
        XCTAssertEqual(MCPProtocolError.notAcceptable().httpStatus, .notAcceptable)
    }

    func testMethodNotAllowedAdvertisesTheAllowedMethods() {
        let error = MCPProtocolError.methodNotAllowed(allow: "POST, OPTIONS")
        XCTAssertEqual(error.httpStatus, .methodNotAllowed)
        XCTAssertEqual(header(error, "Allow"), "POST, OPTIONS")
    }

    func testCancelledAndTimedOutRequestsStayOnHttp200() {
        XCTAssertEqual(MCPProtocolError.requestCancelled().code, JsonRpcErrorCode.requestCancelled)
        XCTAssertEqual(MCPProtocolError.requestCancelled().httpStatus, .ok)
        XCTAssertEqual(MCPProtocolError.requestTimeout(detail: "tools/call").code, JsonRpcErrorCode.requestTimeout)
        XCTAssertEqual(MCPProtocolError.requestTimeout(detail: "tools/call").httpStatus, .ok)
    }

    func testServiceUnavailableAndServerDisabledMapping() {
        XCTAssertEqual(MCPProtocolError.serviceUnavailable().code, JsonRpcErrorCode.serverError)
        XCTAssertEqual(MCPProtocolError.serviceUnavailable().httpStatus, .serviceUnavailable)
        XCTAssertEqual(MCPProtocolError.serverDisabled().code, JsonRpcErrorCode.serverDisabled)
        XCTAssertEqual(MCPProtocolError.serverDisabled().httpStatus, .serviceUnavailable)
    }

    func testToJsonRpcErrorResponseCarriesIdCodeAndData() {
        let protocolError = MCPProtocolError.unsupportedProtocolVersion(requested: "1999-01-01")
        let response = protocolError.toJsonRpcErrorResponse(id: .number(7))
        XCTAssertEqual(response.id, .number(7))
        XCTAssertEqual(response.error.code, JsonRpcErrorCode.unsupportedProtocolVersion)
        XCTAssertEqual(response.error.message, "Unsupported protocol version")
        XCTAssertNotNil(response.error.data?["supported"])
    }

    func testToJsonRpcErrorResponseWithNilId() {
        let response = MCPProtocolError.parseError(detail: "x").toJsonRpcErrorResponse(id: nil)
        XCTAssertNil(response.id)
        XCTAssertEqual(response.error.code, JsonRpcErrorCode.parseError)
    }

    func testEqualityComparesStatusAndHeaders() {
        let base = MCPProtocolError(code: -1, message: "x", httpStatus: .ok)
        let differentStatus = MCPProtocolError(code: -1, message: "x", httpStatus: .badRequest)
        let differentHeaders = MCPProtocolError(
            code: -1,
            message: "x",
            httpStatus: .ok,
            extraHeaders: [("Retry-After", "1")]
        )

        XCTAssertEqual(base, MCPProtocolError(code: -1, message: "x", httpStatus: .ok))
        XCTAssertNotEqual(base, differentStatus)
        XCTAssertNotEqual(base, differentHeaders)
    }

    func testSpecificationCodesLiveInTheReservedRange() {
        for code in JsonRpcErrorCode.specificationDefined {
            XCTAssertTrue(
                JsonRpcErrorCode.isSpecificationReserved(code),
                "\(code) must sit inside the range the specification reserves"
            )
        }
        XCTAssertEqual(
            JsonRpcErrorCode.specificationDefined,
            [
                JsonRpcErrorCode.headerMismatch,
                JsonRpcErrorCode.missingRequiredClientCapability,
                JsonRpcErrorCode.unsupportedProtocolVersion
            ]
        )
    }

    func testTableProCodesLeftTheImplementationDefinedBlock() {
        let tableProCodes = [
            JsonRpcErrorCode.serverError,
            JsonRpcErrorCode.sessionNotFound,
            JsonRpcErrorCode.requestCancelled,
            JsonRpcErrorCode.requestTimeout,
            JsonRpcErrorCode.tooLarge,
            JsonRpcErrorCode.serverDisabled,
            JsonRpcErrorCode.forbidden,
            JsonRpcErrorCode.expired,
            JsonRpcErrorCode.unauthenticated,
            JsonRpcErrorCode.rateLimited
        ]
        for code in tableProCodes {
            XCTAssertTrue(JsonRpcErrorCode.tableProRange.contains(code), "\(code) must be a -33xxx code")
            XCTAssertFalse(
                JsonRpcErrorCode.legacyImplementationRange.contains(code),
                "\(code) must have left the -32000 block"
            )
            XCTAssertFalse(JsonRpcErrorCode.isSpecificationReserved(code), "\(code) must not squat a spec code")
        }
    }
}
