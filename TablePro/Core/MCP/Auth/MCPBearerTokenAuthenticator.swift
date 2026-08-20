import CryptoKit
import Foundation
import os

public struct MCPValidatedToken: Sendable, Equatable {
    public let tokenId: UUID
    public let label: String?
    public let scopes: Set<MCPScope>
    public let connectionAccess: ConnectionAccess
    public let issuedAt: Date
    public let expiresAt: Date?

    public init(
        tokenId: UUID,
        label: String?,
        scopes: Set<MCPScope>,
        connectionAccess: ConnectionAccess,
        issuedAt: Date,
        expiresAt: Date?
    ) {
        self.tokenId = tokenId
        self.label = label
        self.scopes = scopes
        self.connectionAccess = connectionAccess
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }
}

public enum MCPTokenValidationError: Error, Sendable, Equatable {
    case unknownToken
    case expired
    case revoked
}

public protocol MCPTokenStoreProtocol: Sendable {
    func validateBearerToken(_ token: String) async -> Result<MCPValidatedToken, MCPTokenValidationError>
}

extension MCPTokenStore: MCPTokenStoreProtocol {}

internal extension MCPTokenStore {
    func validateBearerToken(_ bearerToken: String) async -> Result<MCPValidatedToken, MCPTokenValidationError> {
        guard let authToken = self.validate(bearerToken: bearerToken) else {
            return .failure(.unknownToken)
        }
        if authToken.isExpired {
            return .failure(.expired)
        }
        if !authToken.isActive {
            return .failure(.revoked)
        }
        let validated = MCPValidatedToken(
            tokenId: authToken.id,
            label: authToken.name,
            scopes: authToken.permissions.scopes,
            connectionAccess: authToken.connectionAccess,
            issuedAt: authToken.createdAt,
            expiresAt: authToken.expiresAt
        )
        return .success(validated)
    }
}

public actor MCPBearerTokenAuthenticator: MCPAuthenticator {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Auth")

    private let tokenStore: any MCPTokenStoreProtocol
    private let rateLimiter: MCPRateLimiter
    private let clock: any MCPClock

    public init(
        tokenStore: any MCPTokenStoreProtocol,
        rateLimiter: MCPRateLimiter,
        clock: any MCPClock = MCPSystemClock()
    ) {
        self.tokenStore = tokenStore
        self.rateLimiter = rateLimiter
        self.clock = clock
    }

    public func authenticate(
        authorizationHeader: String?,
        clientAddress: MCPClientAddress
    ) async -> MCPAuthDecision {
        let ipString = clientAddress.displayValue
        let addressKey = MCPRateLimitKey.authFailure(address: clientAddress)

        if let retry = await lockoutRetryAfter(key: addressKey) {
            MCPAuditLogger.logRateLimited(ip: ipString, retryAfterSeconds: retry)
            return .deny(.rateLimited(retryAfterSeconds: retry))
        }

        guard let header = authorizationHeader, !header.isEmpty else {
            return await denyAttempt(
                addressKey: addressKey,
                ip: ipString,
                reason: "missing_authorization_header",
                denial: .unauthenticated(reason: "missing_authorization_header")
            )
        }

        guard let token = Self.parseBearerToken(header) else {
            return await denyAttempt(
                addressKey: addressKey,
                ip: ipString,
                reason: "invalid_authorization_scheme",
                denial: .unauthenticated(reason: "invalid_authorization_scheme")
            )
        }

        let validation = await tokenStore.validateBearerToken(token)
        switch validation {
        case .failure(let error):
            return await denyAttempt(
                addressKey: addressKey,
                ip: ipString,
                reason: Self.reason(for: error),
                denial: Self.denial(for: error)
            )

        case .success(let validated):
            let tokenKey = MCPRateLimitKey.authFailure(tokenId: validated.tokenId)
            if let retry = await lockoutRetryAfter(key: tokenKey) {
                MCPAuditLogger.logRateLimited(ip: ipString, retryAfterSeconds: retry)
                return .deny(.rateLimited(retryAfterSeconds: retry))
            }
            _ = await rateLimiter.recordAttempt(key: addressKey, success: true)
            _ = await rateLimiter.recordAttempt(key: tokenKey, success: true)

            let principal = MCPPrincipal(
                tokenFingerprint: Self.fingerprint(of: token),
                tokenId: validated.tokenId,
                scopes: validated.scopes,
                connectionAccess: validated.connectionAccess,
                metadata: MCPPrincipalMetadata(
                    label: validated.label,
                    issuedAt: validated.issuedAt,
                    expiresAt: validated.expiresAt
                )
            )
            MCPAuditLogger.logAuthSuccess(
                tokenId: validated.tokenId,
                tokenName: validated.label,
                ip: ipString
            )
            return .allow(principal)
        }
    }

    private func denyAttempt(
        addressKey: MCPRateLimitKey,
        ip: String,
        reason: String,
        denial: MCPAuthDenialReason
    ) async -> MCPAuthDecision {
        let verdict = await rateLimiter.recordAttempt(key: addressKey, success: false)
        if case .lockedUntil(let unlockDate) = verdict {
            let retry = await rateLimiter.retryAfterSeconds(until: unlockDate)
            Self.logger.warning("Auth rate limited: reason=\(reason, privacy: .public)")
            MCPAuditLogger.logRateLimited(ip: ip, retryAfterSeconds: retry)
            return .deny(.rateLimited(retryAfterSeconds: retry))
        }
        Self.logger.info("Auth denied: reason=\(reason, privacy: .public)")
        MCPAuditLogger.logAuthFailure(reason: reason, ip: ip)
        return .deny(denial)
    }

    private func lockoutRetryAfter(key: MCPRateLimitKey) async -> Int? {
        guard let unlockDate = await rateLimiter.lockedUntil(key: key) else { return nil }
        return await rateLimiter.retryAfterSeconds(until: unlockDate)
    }

    private static func reason(for error: MCPTokenValidationError) -> String {
        switch error {
        case .unknownToken:
            return "unknown_token"
        case .expired:
            return "expired_token"
        case .revoked:
            return "revoked_token"
        }
    }

    private static func denial(for error: MCPTokenValidationError) -> MCPAuthDenialReason {
        switch error {
        case .unknownToken:
            return .tokenInvalid(reason: "unknown_token")
        case .expired:
            return .tokenExpired()
        case .revoked:
            return .tokenInvalid(reason: "token_revoked")
        }
    }

    internal static func parseBearerToken(_ header: String) -> String? {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let spaceIndex = trimmed.firstIndex(of: " ") else { return nil }
        let scheme = trimmed[trimmed.startIndex..<spaceIndex]
        guard scheme.lowercased() == "bearer" else { return nil }
        let value = trimmed[trimmed.index(after: spaceIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    internal static func fingerprint(of token: String) -> String {
        guard let data = token.data(using: .utf8) else { return "" }
        let digest = SHA256.hash(data: data)
        return String(digest.hexEncoded.prefix(16))
    }
}
