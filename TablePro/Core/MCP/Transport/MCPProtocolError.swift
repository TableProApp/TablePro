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
        lhs.code == rhs.code && lhs.message == rhs.message
    }
}

public extension MCPProtocolError {
    static func sessionNotFound(message: String = "Session not found") -> Self {
        Self(code: JsonRpcErrorCode.sessionNotFound, message: message, httpStatus: .notFound)
    }

    static func missingSessionId(message: String = "Missing Mcp-Session-Id header") -> Self {
        Self(code: JsonRpcErrorCode.invalidRequest, message: message, httpStatus: .badRequest)
    }

    static func parseError(detail: String) -> Self {
        Self(
            code: JsonRpcErrorCode.parseError,
            message: "Parse error: \(detail)",
            httpStatus: .badRequest
        )
    }

    static func invalidRequest(detail: String) -> Self {
        Self(
            code: JsonRpcErrorCode.invalidRequest,
            message: "Invalid request: \(detail)",
            httpStatus: .badRequest
        )
    }

    static func methodNotFound(method: String) -> Self {
        Self(
            code: JsonRpcErrorCode.methodNotFound,
            message: "Method not found: \(method)",
            httpStatus: .ok
        )
    }

    static func invalidParams(detail: String) -> Self {
        Self(
            code: JsonRpcErrorCode.invalidParams,
            message: "Invalid params: \(detail)",
            httpStatus: .ok
        )
    }

    static func internalError(detail: String) -> Self {
        Self(
            code: JsonRpcErrorCode.internalError,
            message: "Internal error: \(detail)",
            httpStatus: .internalServerError
        )
    }

    static func unauthenticated(challenge: String = "Bearer realm=\"TablePro\"") -> Self {
        Self(
            code: JsonRpcErrorCode.unauthenticated,
            message: "Unauthenticated",
            httpStatus: .unauthorized,
            extraHeaders: [("WWW-Authenticate", challenge)]
        )
    }

    static func tokenInvalid() -> Self {
        Self(
            code: JsonRpcErrorCode.forbidden,
            message: "Token invalid",
            httpStatus: .unauthorized,
            extraHeaders: [("WWW-Authenticate", "Bearer error=\"invalid_token\"")]
        )
    }

    static func tokenExpired() -> Self {
        Self(
            code: JsonRpcErrorCode.expired,
            message: "Token expired",
            httpStatus: .unauthorized,
            extraHeaders: [("WWW-Authenticate", "Bearer error=\"invalid_token\", error_description=\"token expired\"")]
        )
    }

    static func forbidden(reason: String) -> Self {
        Self(
            code: JsonRpcErrorCode.forbidden,
            message: "Forbidden: \(reason)",
            httpStatus: .forbidden
        )
    }

    static func rateLimited(retryAfterSeconds: Int? = nil) -> Self {
        var headers: [(String, String)] = []
        if let retryAfterSeconds, retryAfterSeconds > 0 {
            headers.append(("Retry-After", String(retryAfterSeconds)))
        }
        return Self(
            code: JsonRpcErrorCode.serverError,
            message: "Rate limited",
            httpStatus: .tooManyRequests,
            extraHeaders: headers
        )
    }

    static func payloadTooLarge() -> Self {
        Self(
            code: JsonRpcErrorCode.tooLarge,
            message: "Payload too large",
            httpStatus: .payloadTooLarge
        )
    }

    static func notAcceptable() -> Self {
        Self(
            code: JsonRpcErrorCode.invalidRequest,
            message: "Not acceptable",
            httpStatus: .notAcceptable
        )
    }

    static func unsupportedMediaType() -> Self {
        Self(
            code: JsonRpcErrorCode.invalidRequest,
            message: "Unsupported media type",
            httpStatus: .unsupportedMediaType
        )
    }

    static func serviceUnavailable() -> Self {
        Self(
            code: JsonRpcErrorCode.serverError,
            message: "Service unavailable",
            httpStatus: .serviceUnavailable
        )
    }
}

public extension MCPProtocolError {
    func toJsonRpcErrorResponse(id: JsonRpcId?) -> JsonRpcErrorResponse {
        JsonRpcErrorResponse(id: id, error: JsonRpcError(code: code, message: message, data: data))
    }
}
