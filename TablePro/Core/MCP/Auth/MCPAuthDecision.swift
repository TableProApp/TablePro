import Foundation

public enum MCPAuthDecision: Sendable {
    case allow(MCPPrincipal)
    case deny(MCPAuthDenialReason)
}

public struct MCPAuthDenialReason: Sendable, Equatable {
    public let httpStatus: Int
    public let challenge: String?
    public let logMessage: String
    public let retryAfterSeconds: Int?

    public init(
        httpStatus: Int,
        challenge: String?,
        logMessage: String,
        retryAfterSeconds: Int? = nil
    ) {
        self.httpStatus = httpStatus
        self.challenge = challenge
        self.logMessage = logMessage
        self.retryAfterSeconds = retryAfterSeconds
    }

    public static func unauthenticated(reason: String) -> Self {
        Self(
            httpStatus: 401,
            challenge: "Bearer realm=\"TablePro MCP\"",
            logMessage: reason
        )
    }

    public static func tokenExpired() -> Self {
        Self(
            httpStatus: 401,
            challenge: "Bearer realm=\"TablePro MCP\", error=\"invalid_token\", error_description=\"token_expired\"",
            logMessage: "token_expired"
        )
    }

    public static func tokenInvalid(reason: String) -> Self {
        Self(
            httpStatus: 401,
            challenge: "Bearer realm=\"TablePro MCP\", error=\"invalid_token\"",
            logMessage: reason
        )
    }

    public static func forbidden(reason: String) -> Self {
        Self(
            httpStatus: 403,
            challenge: nil,
            logMessage: reason
        )
    }

    public static func rateLimited(retryAfterSeconds: Int? = nil) -> Self {
        Self(
            httpStatus: 429,
            challenge: nil,
            logMessage: "rate_limited",
            retryAfterSeconds: retryAfterSeconds
        )
    }
}
