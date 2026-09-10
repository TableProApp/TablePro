import Foundation

public enum MCPAuthDecision: Sendable {
    case allow(MCPPrincipal)
    case deny(MCPAuthDenialReason)
}

public enum MCPAuthDenialKind: Sendable, Equatable {
    case unauthenticated
    case tokenInvalid
    case tokenExpired
    case insufficientScope(Set<MCPScope>)
    case forbidden
    case rateLimited
}

public struct MCPAuthDenialReason: Sendable, Equatable {
    public let kind: MCPAuthDenialKind
    public let challenge: MCPAuthChallenge?
    public let logMessage: String
    public let retryAfterSeconds: Int?

    public init(
        kind: MCPAuthDenialKind,
        challenge: MCPAuthChallenge?,
        logMessage: String,
        retryAfterSeconds: Int? = nil
    ) {
        self.kind = kind
        self.challenge = challenge
        self.logMessage = logMessage
        self.retryAfterSeconds = retryAfterSeconds
    }

    public var httpStatus: Int {
        switch kind {
        case .unauthenticated, .tokenInvalid, .tokenExpired:
            return 401
        case .insufficientScope, .forbidden:
            return 403
        case .rateLimited:
            return 429
        }
    }

    public var asProtocolError: MCPProtocolError {
        switch kind {
        case .unauthenticated:
            return .unauthenticated(challenge: challenge ?? .bearerRealm)
        case .tokenInvalid:
            return .tokenInvalid()
        case .tokenExpired:
            return .tokenExpired()
        case .insufficientScope(let required):
            return .insufficientScope(required: required, reason: logMessage)
        case .forbidden:
            return .forbidden(reason: logMessage)
        case .rateLimited:
            return .rateLimited(retryAfterSeconds: retryAfterSeconds)
        }
    }

    public static func unauthenticated(reason: String) -> Self {
        Self(kind: .unauthenticated, challenge: .bearerRealm, logMessage: reason)
    }

    public static func tokenExpired() -> Self {
        Self(
            kind: .tokenExpired,
            challenge: .invalidToken(description: "token expired"),
            logMessage: "token_expired"
        )
    }

    public static func tokenInvalid(reason: String) -> Self {
        Self(kind: .tokenInvalid, challenge: .invalidToken(description: nil), logMessage: reason)
    }

    public static func insufficientScope(required: Set<MCPScope>, reason: String) -> Self {
        Self(
            kind: .insufficientScope(required),
            challenge: .insufficientScope(scopes: required.map(\.rawValue).sorted(), description: reason),
            logMessage: reason
        )
    }

    public static func forbidden(reason: String) -> Self {
        Self(kind: .forbidden, challenge: nil, logMessage: reason)
    }

    public static func rateLimited(retryAfterSeconds: Int? = nil) -> Self {
        Self(
            kind: .rateLimited,
            challenge: nil,
            logMessage: "rate_limited",
            retryAfterSeconds: retryAfterSeconds
        )
    }
}
