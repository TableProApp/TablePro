import Foundation
@testable import TableProMCP
import Testing

struct MCPProtocolErrorTests {
    private func header(_ error: MCPProtocolError, _ name: String) -> String? {
        error.extraHeaders.first { $0.0.lowercased() == name.lowercased() }?.1
    }

    @Test func testHeaderMismatchIsTheSpecCodeWithBadRequest() {
        let error = MCPProtocolError.headerMismatch(detail: "Mcp-Name header is required for tools/call")
        #expect(error.code == -32_020)
        #expect(error.code == JsonRpcErrorCode.headerMismatch)
        #expect(error.httpStatus == .badRequest)
        #expect(error.message.contains("Mcp-Name"))
    }

    @Test func testMissingRequiredClientCapabilityListsTheCapabilities() {
        let error = MCPProtocolError.missingRequiredClientCapability(["elicitation"])
        #expect(error.code == -32_021)
        #expect(error.httpStatus == .badRequest)
        #expect(error.data?["requiredCapabilities"]?.arrayValue?.compactMap(\.stringValue) == ["elicitation"])
    }

    @Test func testUnsupportedProtocolVersionListsTheSupportedVersions() {
        let error = MCPProtocolError.unsupportedProtocolVersion(requested: "2024-11-05")
        #expect(error.code == -32_022)
        #expect(error.httpStatus == .badRequest)
        #expect(error.data?["supported"]?.arrayValue?.compactMap(\.stringValue) == MCPProtocolVersion.supportedRawValues)
        #expect(error.data?["requested"]?.stringValue == "2024-11-05")
    }

    @Test func testUnsupportedProtocolVersionOmitsRequestedWhenUnknown() {
        let error = MCPProtocolError.unsupportedProtocolVersion(requested: nil)
        #expect(error.data?["requested"] == nil)
        #expect(error.data?["supported"] != nil)
    }

    @Test func testMethodNotFoundCarriesHttp404() {
        let error = MCPProtocolError.methodNotFound(method: "tools/teleport")
        #expect(error.code == JsonRpcErrorCode.methodNotFound)
        #expect(error.httpStatus == .notFound)
    }

    @Test func testNotFoundIsInvalidParams() {
        let error = MCPProtocolError.notFound(detail: "No such resource")
        #expect(error.code == -32_602)
        #expect(error.code == JsonRpcErrorCode.invalidParams)
        #expect(error.httpStatus == .badRequest)
        #expect(error.message == "No such resource")
    }

    @Test func testInvalidParamsMapping() {
        let error = MCPProtocolError.invalidParams(detail: "expected object")
        #expect(error.code == JsonRpcErrorCode.invalidParams)
        #expect(error.httpStatus == .badRequest)
    }

    @Test func testParseErrorMapping() {
        let error = MCPProtocolError.parseError(detail: "bad json")
        #expect(error.code == JsonRpcErrorCode.parseError)
        #expect(error.httpStatus == .badRequest)
        #expect(error.message.contains("bad json"))
    }

    @Test func testInvalidRequestMapping() {
        let error = MCPProtocolError.invalidRequest(detail: "missing method")
        #expect(error.code == JsonRpcErrorCode.invalidRequest)
        #expect(error.httpStatus == .badRequest)
    }

    @Test func testInternalErrorMapping() {
        let error = MCPProtocolError.internalError(detail: "boom")
        #expect(error.code == JsonRpcErrorCode.internalError)
        #expect(error.httpStatus == .internalServerError)
    }

    @Test func testUnauthenticatedCarriesABearerChallenge() {
        let error = MCPProtocolError.unauthenticated()
        #expect(error.code == JsonRpcErrorCode.unauthenticated)
        #expect(error.httpStatus == .unauthorized)
        #expect(header(error, "WWW-Authenticate") == "Bearer realm=\"TablePro\"")
    }

    @Test func testTokenInvalidNamesTheInvalidTokenError() {
        let error = MCPProtocolError.tokenInvalid()
        #expect(error.httpStatus == .unauthorized)
        #expect(header(error, "WWW-Authenticate") == "Bearer realm=\"TablePro\", error=\"invalid_token\"")
    }

    @Test func testTokenExpiredDescribesTheExpiry() throws {
        let error = MCPProtocolError.tokenExpired()
        #expect(error.code == JsonRpcErrorCode.expired)
        #expect(error.httpStatus == .unauthorized)
        let challenge = try #require(header(error, "WWW-Authenticate"))
        #expect(challenge.contains("error=\"invalid_token\""))
        #expect(challenge.contains("error_description=\"token expired\""))
    }

    @Test func testInsufficientScopeEmitsAStructuredChallengeAndData() throws {
        let error = MCPProtocolError.insufficientScope(
            required: [.toolsWrite, .toolsRead],
            reason: "tools/call requires tools:write"
        )
        #expect(error.code == JsonRpcErrorCode.forbidden)
        #expect(error.httpStatus == .forbidden)
        let challenge = try #require(header(error, "WWW-Authenticate"))
        #expect(challenge.contains("error=\"insufficient_scope\""))
        #expect(challenge.contains("scope=\"tools:read tools:write\""))
        #expect(error.data?["requiredScopes"]?.arrayValue?.compactMap(\.stringValue) == ["tools:read", "tools:write"])
    }

    @Test func testForbiddenMapping() {
        let error = MCPProtocolError.forbidden(reason: "policy")
        #expect(error.code == JsonRpcErrorCode.forbidden)
        #expect(error.httpStatus == .forbidden)
    }

    @Test func testRateLimitedIncludesRetryAfterOnlyWhenPositive() {
        let withRetry = MCPProtocolError.rateLimited(retryAfterSeconds: 30)
        #expect(withRetry.code == JsonRpcErrorCode.rateLimited)
        #expect(withRetry.httpStatus == .tooManyRequests)
        #expect(header(withRetry, "Retry-After") == "30")

        #expect(header(MCPProtocolError.rateLimited(), "Retry-After") == nil)
        #expect(header(MCPProtocolError.rateLimited(retryAfterSeconds: 0), "Retry-After") == nil)
    }

    @Test func testPayloadTooLargeMapping() {
        let error = MCPProtocolError.payloadTooLarge()
        #expect(error.code == JsonRpcErrorCode.tooLarge)
        #expect(error.httpStatus == .payloadTooLarge)
    }

    @Test func testNotAcceptableMapping() {
        #expect(MCPProtocolError.notAcceptable().httpStatus == .notAcceptable)
    }

    @Test func testMethodNotAllowedAdvertisesTheAllowedMethods() {
        let error = MCPProtocolError.methodNotAllowed(allow: "POST, OPTIONS")
        #expect(error.httpStatus == .methodNotAllowed)
        #expect(header(error, "Allow") == "POST, OPTIONS")
    }

    @Test func testCancelledAndTimedOutRequestsStayOnHttp200() {
        #expect(MCPProtocolError.requestCancelled().code == JsonRpcErrorCode.requestCancelled)
        #expect(MCPProtocolError.requestCancelled().httpStatus == .ok)
        #expect(MCPProtocolError.requestTimeout(detail: "tools/call").code == JsonRpcErrorCode.requestTimeout)
        #expect(MCPProtocolError.requestTimeout(detail: "tools/call").httpStatus == .ok)
    }

    @Test func testServiceUnavailableAndServerDisabledMapping() {
        #expect(MCPProtocolError.serviceUnavailable().code == JsonRpcErrorCode.serverError)
        #expect(MCPProtocolError.serviceUnavailable().httpStatus == .serviceUnavailable)
        #expect(MCPProtocolError.serverDisabled().code == JsonRpcErrorCode.serverDisabled)
        #expect(MCPProtocolError.serverDisabled().httpStatus == .serviceUnavailable)
    }

    @Test func testToJsonRpcErrorResponseCarriesIdCodeAndData() {
        let protocolError = MCPProtocolError.unsupportedProtocolVersion(requested: "1999-01-01")
        let response = protocolError.toJsonRpcErrorResponse(id: .number(7))
        #expect(response.id == .number(7))
        #expect(response.error.code == JsonRpcErrorCode.unsupportedProtocolVersion)
        #expect(response.error.message == "Unsupported protocol version")
        #expect(response.error.data?["supported"] != nil)
    }

    @Test func testToJsonRpcErrorResponseWithNilId() {
        let response = MCPProtocolError.parseError(detail: "x").toJsonRpcErrorResponse(id: nil)
        #expect(response.id == nil)
        #expect(response.error.code == JsonRpcErrorCode.parseError)
    }

    @Test func testEqualityComparesStatusAndHeaders() {
        let base = MCPProtocolError(code: -1, message: "x", httpStatus: .ok)
        let differentStatus = MCPProtocolError(code: -1, message: "x", httpStatus: .badRequest)
        let differentHeaders = MCPProtocolError(
            code: -1,
            message: "x",
            httpStatus: .ok,
            extraHeaders: [("Retry-After", "1")]
        )

        #expect(base == MCPProtocolError(code: -1, message: "x", httpStatus: .ok))
        #expect(base != differentStatus)
        #expect(base != differentHeaders)
    }

    @Test func testSpecificationCodesLiveInTheReservedRange() {
        for code in JsonRpcErrorCode.specificationDefined {
            #expect(JsonRpcErrorCode.isSpecificationReserved(code), "\(code) must sit inside the range the specification reserves")
        }
        #expect(JsonRpcErrorCode.specificationDefined == [
            JsonRpcErrorCode.headerMismatch,
            JsonRpcErrorCode.missingRequiredClientCapability,
            JsonRpcErrorCode.unsupportedProtocolVersion
        ])
    }

    @Test func testTableProCodesLeftTheImplementationDefinedBlock() {
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
            #expect(JsonRpcErrorCode.tableProRange.contains(code), "\(code) must be a -33xxx code")
            #expect(!JsonRpcErrorCode.legacyImplementationRange.contains(code), "\(code) must have left the -32000 block")
            #expect(!JsonRpcErrorCode.isSpecificationReserved(code), "\(code) must not squat a spec code")
        }
    }
}
