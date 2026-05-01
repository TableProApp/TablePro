import CryptoKit
import Foundation
import os

public struct MCPValidatedToken: Sendable, Equatable {
    public let label: String?
    public let scopes: Set<MCPScope>
    public let issuedAt: Date
    public let expiresAt: Date?

    public init(label: String?, scopes: Set<MCPScope>, issuedAt: Date, expiresAt: Date?) {
        self.label = label
        self.scopes = scopes
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
            label: authToken.name,
            scopes: Self.mcpScopes(for: authToken.permissions),
            issuedAt: authToken.createdAt,
            expiresAt: authToken.expiresAt
        )
        return .success(validated)
    }

    private static func mcpScopes(for permissions: TokenPermissions) -> Set<MCPScope> {
        switch permissions {
        case .readOnly:
            return [.toolsRead, .resourcesRead]
        case .readWrite:
            return [.toolsRead, .toolsWrite, .resourcesRead]
        case .fullAccess:
            return [.toolsRead, .toolsWrite, .resourcesRead, .admin]
        }
    }
}

public actor MCPBearerTokenAuthenticator: MCPAuthenticator {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Auth")

    private let tokenStore: any MCPTokenStoreProtocol
    private let rateLimiter: MCPRateLimiter

    public init(tokenStore: any MCPTokenStoreProtocol, rateLimiter: MCPRateLimiter) {
        self.tokenStore = tokenStore
        self.rateLimiter = rateLimiter
    }

    public func authenticate(
        authorizationHeader: String?,
        clientAddress: MCPClientAddress
    ) async -> MCPAuthDecision {
        guard let header = authorizationHeader, !header.isEmpty else {
            let key = MCPRateLimitKey(clientAddress: clientAddress, principalFingerprint: nil)
            if await rateLimiter.isLocked(key: key) {
                Self.logger.warning("Auth rejected (rate limited, missing header)")
                return .deny(.rateLimited())
            }
            Self.logger.info("Auth missing Authorization header")
            return .deny(.unauthenticated(reason: "missing_authorization_header"))
        }

        guard let token = Self.parseBearerToken(header) else {
            let key = MCPRateLimitKey(clientAddress: clientAddress, principalFingerprint: nil)
            if await rateLimiter.isLocked(key: key) {
                return .deny(.rateLimited())
            }
            _ = await rateLimiter.recordAttempt(key: key, success: false)
            Self.logger.info("Auth invalid Authorization scheme")
            return .deny(.unauthenticated(reason: "invalid_authorization_scheme"))
        }

        let fingerprint = Self.fingerprint(of: token)
        let principalKey = MCPRateLimitKey(
            clientAddress: clientAddress,
            principalFingerprint: fingerprint
        )

        if await rateLimiter.isLocked(key: principalKey) {
            Self.logger.warning(
                "Auth rate limited fingerprint=\(fingerprint, privacy: .public)"
            )
            return .deny(.rateLimited())
        }

        let validation = await tokenStore.validateBearerToken(token)
        switch validation {
        case .failure(let error):
            let verdict = await rateLimiter.recordAttempt(key: principalKey, success: false)
            if case .lockedUntil = verdict {
                return .deny(.rateLimited())
            }
            switch error {
            case .unknownToken:
                Self.logger.info("Auth unknown token fingerprint=\(fingerprint, privacy: .public)")
                return .deny(.tokenInvalid(reason: "unknown_token"))
            case .expired:
                Self.logger.info("Auth expired token fingerprint=\(fingerprint, privacy: .public)")
                return .deny(.tokenExpired())
            case .revoked:
                Self.logger.info("Auth revoked token fingerprint=\(fingerprint, privacy: .public)")
                return .deny(.tokenInvalid(reason: "token_revoked"))
            }

        case .success(let validated):
            _ = await rateLimiter.recordAttempt(key: principalKey, success: true)
            let principal = MCPPrincipal(
                tokenFingerprint: fingerprint,
                scopes: validated.scopes,
                metadata: MCPPrincipalMetadata(
                    label: validated.label,
                    issuedAt: validated.issuedAt,
                    expiresAt: validated.expiresAt
                )
            )
            Self.logger.info("Auth allowed fingerprint=\(fingerprint, privacy: .public)")
            return .allow(principal)
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
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(8))
    }
}
