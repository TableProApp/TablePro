import Foundation

public struct MCPProtocolError: LocalizedError, Sendable, Equatable {
    public var errorDescription: String? { message }
    public let code: Int
    public let message: String
    public let httpStatus: HttpStatus
    public let extraHeaders: [(String, String)]
    public let data: JsonValue?

    public init(
        code: Int,
        message: String,
        httpStatus: HttpStatus,
        extraHeaders: [(String, String)] = [],
        data: JsonValue? = nil
    ) {
        self.code = code
        self.message = message
        self.httpStatus = httpStatus
        self.extraHeaders = extraHeaders
        self.data = data
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.code == rhs.code
            && lhs.message == rhs.message
            && lhs.httpStatus == rhs.httpStatus
            && lhs.data == rhs.data
            && lhs.extraHeaders.map(\.0) == rhs.extraHeaders.map(\.0)
            && lhs.extraHeaders.map(\.1) == rhs.extraHeaders.map(\.1)
    }
}

public extension MCPProtocolError {
    static func parseError(detail: String) -> Self {
        Self(code: JsonRpcErrorCode.parseError, message: "Parse error: \(detail)", httpStatus: .badRequest)
    }

    static func invalidRequest(detail: String) -> Self {
        Self(code: JsonRpcErrorCode.invalidRequest, message: "Invalid request: \(detail)", httpStatus: .badRequest)
    }

    static func methodNotFound(method: String) -> Self {
        Self(
            code: JsonRpcErrorCode.methodNotFound,
            message: "Method not found: \(method)",
            httpStatus: .notFound
        )
    }

    static func invalidParams(detail: String) -> Self {
        Self(code: JsonRpcErrorCode.invalidParams, message: "Invalid params: \(detail)", httpStatus: .badRequest)
    }

    static func notFound(detail: String) -> Self {
        Self(code: JsonRpcErrorCode.invalidParams, message: detail, httpStatus: .badRequest)
    }

    static func internalError(detail: String) -> Self {
        Self(
            code: JsonRpcErrorCode.internalError,
            message: "Internal error: \(detail)",
            httpStatus: .internalServerError
        )
    }

    static func headerMismatch(detail: String) -> Self {
        Self(
            code: JsonRpcErrorCode.headerMismatch,
            message: "Header mismatch: \(detail)",
            httpStatus: .badRequest
        )
    }

    static func unsupportedProtocolVersion(requested: String?) -> Self {
        var payload: [String: JsonValue] = [
            "supported": .array(MCPProtocolVersion.supportedRawValues.map { .string($0) })
        ]
        if let requested {
            payload["requested"] = .string(requested)
        }
        return Self(
            code: JsonRpcErrorCode.unsupportedProtocolVersion,
            message: "Unsupported protocol version",
            httpStatus: .badRequest,
            data: .object(payload)
        )
    }

    static func missingRequiredClientCapability(_ capabilities: [String]) -> Self {
        Self(
            code: JsonRpcErrorCode.missingRequiredClientCapability,
            message: "Missing required client capability",
            httpStatus: .badRequest,
            data: .object(["requiredCapabilities": .array(capabilities.map { .string($0) })])
        )
    }

    static func unauthenticated(challenge: MCPAuthChallenge = .bearerRealm) -> Self {
        Self(
            code: JsonRpcErrorCode.unauthenticated,
            message: "Unauthenticated",
            httpStatus: .unauthorized,
            extraHeaders: [("WWW-Authenticate", challenge.headerValue)]
        )
    }

    static func tokenInvalid() -> Self {
        Self(
            code: JsonRpcErrorCode.unauthenticated,
            message: "Token invalid",
            httpStatus: .unauthorized,
            extraHeaders: [("WWW-Authenticate", MCPAuthChallenge.invalidToken(description: nil).headerValue)]
        )
    }

    static func tokenExpired() -> Self {
        Self(
            code: JsonRpcErrorCode.expired,
            message: "Token expired",
            httpStatus: .unauthorized,
            extraHeaders: [
                ("WWW-Authenticate", MCPAuthChallenge.invalidToken(description: "token expired").headerValue)
            ]
        )
    }

    static func forbidden(reason: String) -> Self {
        Self(code: JsonRpcErrorCode.forbidden, message: "Forbidden: \(reason)", httpStatus: .forbidden)
    }

    static func insufficientScope(required: Set<MCPScope>, reason: String) -> Self {
        let scopes = required.map(\.rawValue).sorted()
        return Self(
            code: JsonRpcErrorCode.forbidden,
            message: "Forbidden: \(reason)",
            httpStatus: .forbidden,
            extraHeaders: [
                ("WWW-Authenticate", MCPAuthChallenge.insufficientScope(scopes: scopes, description: reason).headerValue)
            ],
            data: .object(["requiredScopes": .array(scopes.map { .string($0) })])
        )
    }

    static func rateLimited(retryAfterSeconds: Int? = nil) -> Self {
        var headers: [(String, String)] = []
        if let retryAfterSeconds, retryAfterSeconds > 0 {
            headers.append(("Retry-After", String(retryAfterSeconds)))
        }
        return Self(
            code: JsonRpcErrorCode.rateLimited,
            message: "Rate limited",
            httpStatus: .tooManyRequests,
            extraHeaders: headers
        )
    }

    static func payloadTooLarge() -> Self {
        Self(code: JsonRpcErrorCode.tooLarge, message: "Payload too large", httpStatus: .payloadTooLarge)
    }

    static func notAcceptable() -> Self {
        Self(code: JsonRpcErrorCode.invalidRequest, message: "Not acceptable", httpStatus: .notAcceptable)
    }

    static func methodNotAllowed(allow: String) -> Self {
        Self(
            code: JsonRpcErrorCode.invalidRequest,
            message: "Method not allowed",
            httpStatus: .methodNotAllowed,
            extraHeaders: [("Allow", allow)]
        )
    }

    static func requestCancelled() -> Self {
        Self(code: JsonRpcErrorCode.requestCancelled, message: "Request cancelled", httpStatus: .ok)
    }

    static func requestTimeout(detail: String) -> Self {
        Self(code: JsonRpcErrorCode.requestTimeout, message: "Timeout: \(detail)", httpStatus: .ok)
    }

    static func serviceUnavailable() -> Self {
        Self(code: JsonRpcErrorCode.serverError, message: "Service unavailable", httpStatus: .serviceUnavailable)
    }

    static func serverDisabled() -> Self {
        Self(code: JsonRpcErrorCode.serverDisabled, message: "Server disabled", httpStatus: .serviceUnavailable)
    }
}

public extension MCPProtocolError {
    func toJsonRpcErrorResponse(id: JsonRpcId?) -> JsonRpcErrorResponse {
        JsonRpcErrorResponse(id: id, error: JsonRpcError(code: code, message: message, data: data))
    }
}
