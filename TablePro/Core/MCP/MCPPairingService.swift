import AppKit
import CryptoKit
import Foundation
import os

struct PairingExchangeRecord: Sendable, Equatable {
    let plaintextToken: String
    let tokenId: UUID
    let challenge: String
    let expiresAt: Date
}

/// A failed verification burns the code. PKCE protects the exchange only while each code allows one
/// attempt; leaving a code alive after a mismatch turns the five-minute window into an offline
/// guessing game against a value the caller can retry without limit.
actor PairingExchangeStore {
    static let exchangeWindow: TimeInterval = 300
    static let maxPendingCodes = 50

    private var pending: [String: PairingExchangeRecord] = [:]

    func insert(code: String, record: PairingExchangeRecord) throws {
        prune(now: Date.now)
        guard pending.count < Self.maxPendingCodes else {
            throw DatabaseAccessError.forbidden(
                String(localized: "Too many pending pairing codes. Try again later.")
            )
        }
        pending[code] = record
    }

    func consume(code: String, verifier: String, now: Date = .now) throws -> PairingExchangeRecord {
        guard let entry = pending[code] else {
            prune(now: now)
            throw DatabaseAccessError.notFound("pairing code")
        }

        guard entry.expiresAt > now else {
            pending.removeValue(forKey: code)
            prune(now: now)
            throw DatabaseAccessError.expired("pairing code")
        }

        let computed = Self.sha256Base64Url(of: verifier)
        guard Self.constantTimeEqual(entry.challenge, computed) else {
            pending.removeValue(forKey: code)
            throw DatabaseAccessError.forbidden("challenge mismatch")
        }

        pending.removeValue(forKey: code)
        return entry
    }

    func discard(code: String) {
        pending.removeValue(forKey: code)
    }

    func pruneExpired(now: Date = .now) {
        prune(now: now)
    }

    func count() -> Int {
        pending.count
    }

    func contains(code: String) -> Bool {
        pending[code] != nil
    }

    private func prune(now: Date) {
        let stale = pending.filter { $0.value.expiresAt <= now }.keys
        for key in stale {
            pending.removeValue(forKey: key)
        }
    }

    static func sha256Base64Url(of value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        guard lhsBytes.count == rhsBytes.count else { return false }
        var result: UInt8 = 0
        for index in 0..<lhsBytes.count {
            result |= lhsBytes[index] ^ rhsBytes[index]
        }
        return result == 0
    }
}

@MainActor
final class MCPPairingService {
    static let shared = MCPPairingService()

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "MCPPairingService")
    private static let pruneInterval: Duration = .seconds(60)
    static let exchangeRateLimitPolicy = MCPRateLimitPolicy(
        maxFailedAttempts: 5,
        windowDuration: .seconds(300),
        lockoutDuration: .seconds(900)
    )

    let store: PairingExchangeStore
    private let rateLimiter: MCPRateLimiter
    private var pruneTask: Task<Void, Never>?

    init(
        store: PairingExchangeStore = PairingExchangeStore(),
        rateLimiter: MCPRateLimiter = MCPRateLimiter(
            pairingPolicy: MCPPairingService.exchangeRateLimitPolicy
        )
    ) {
        self.store = store
        self.rateLimiter = rateLimiter
        startPruneLoop()
    }

    func startPairing(_ request: PairingRequest) async throws {
        let target: PairingRedirectTarget
        do {
            target = try PairingRedirectValidator.validate(request.redirectURL)
            try PairingPkceValidator.validateChallenge(request.challenge)
        } catch let error as PairingValidationError {
            Self.logger.warning("Pairing rejected: \(error.reason, privacy: .public)")
            MCPAuditLogger.logPairingRedirectRejected(
                clientName: request.clientName,
                ip: MCPClientAddress.loopback.displayValue,
                reason: error.reason
            )
            throw DatabaseAccessError.invalidArgument(error.localizedMessage)
        }

        await MCPServerManager.shared.lazyStart()

        guard let tokenStore = MCPServerManager.shared.tokenStore else {
            Self.logger.error("Token store unavailable after lazyStart")
            throw DatabaseAccessError.dataSourceError("Token store unavailable")
        }

        let approval: PairingApproval
        do {
            approval = try await AlertHelper.runPairingApproval(request: request)
        } catch let error as DatabaseAccessError where error.isUserCancelled {
            Self.logger.info("Pairing denied for client '\(request.clientName, privacy: .public)'")
            if let redirect = buildErrorRedirect(
                base: target.url,
                error: "denied",
                description: "user_denied"
            ) {
                NSWorkspace.shared.open(redirect)
            }
            throw error
        }

        let connectionAccess: ConnectionAccess = approval.allowedConnectionIds.map { .limited($0) } ?? .all
        let result = try await tokenStore.generate(
            name: request.clientName,
            permissions: approval.grantedPermissions,
            connectionAccess: connectionAccess,
            expiresAt: approval.expiresAt
        )

        let code = UUID().uuidString
        do {
            try await store.insert(
                code: code,
                record: PairingExchangeRecord(
                    plaintextToken: result.plaintext,
                    tokenId: result.token.id,
                    challenge: request.challenge,
                    expiresAt: Date.now.addingTimeInterval(PairingExchangeStore.exchangeWindow)
                )
            )
        } catch {
            await tokenStore.delete(tokenId: result.token.id)
            throw error
        }

        guard let redirect = buildRedirectURL(base: target.url, code: code) else {
            Self.logger.error("Failed to build pairing redirect URL")
            await store.discard(code: code)
            await tokenStore.delete(tokenId: result.token.id)
            throw DatabaseAccessError.invalidArgument("redirect URL")
        }

        Self.logger.info(
            """
            Pairing approved for client '\(request.clientName, privacy: .public)' \
            redirect=\(target.displayValue, privacy: .public)
            """
        )
        NSWorkspace.shared.open(redirect)
    }

    func exchange(_ exchange: PairingExchange, clientAddress: MCPClientAddress) async throws -> String {
        let key = MCPRateLimitKey.pairingExchange(address: clientAddress)
        if let unlockDate = await rateLimiter.lockedUntil(key: key) {
            let retry = await rateLimiter.retryAfterSeconds(until: unlockDate)
            MCPAuditLogger.logPairingExchange(
                outcome: .rateLimited,
                ip: clientAddress.displayValue,
                details: "retryAfter=\(retry)s"
            )
            throw MCPProtocolError.rateLimited(retryAfterSeconds: retry)
        }

        do {
            try PairingPkceValidator.validateVerifier(exchange.verifier)
        } catch let error as PairingValidationError {
            await store.discard(code: exchange.code)
            _ = await rateLimiter.recordAttempt(key: key, success: false)
            throw DatabaseAccessError.invalidArgument(error.localizedMessage)
        }

        do {
            let record = try await store.consume(code: exchange.code, verifier: exchange.verifier)
            _ = await rateLimiter.recordAttempt(key: key, success: true)
            MCPAuditLogger.logPairingExchange(
                outcome: .success,
                tokenId: record.tokenId,
                ip: clientAddress.displayValue
            )
            return record.plaintextToken
        } catch {
            _ = await rateLimiter.recordAttempt(key: key, success: false)
            throw error
        }
    }

    private func startPruneLoop() {
        pruneTask = Task { [store] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pruneInterval)
                guard !Task.isCancelled else { return }
                await store.pruneExpired()
            }
        }
    }

    private func buildErrorRedirect(base: URL, error: String, description: String) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var items = components.queryItems ?? []
        if base.scheme == "raycast" {
            let payload: [String: String] = ["error": error, "error_description": description]
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
                  let json = String(data: data, encoding: .utf8) else {
                return nil
            }
            items.append(URLQueryItem(name: "context", value: json))
        } else {
            items.append(URLQueryItem(name: "error", value: error))
            items.append(URLQueryItem(name: "error_description", value: description))
        }
        components.queryItems = items
        return components.url
    }

    private func buildRedirectURL(base: URL, code: String) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var items = components.queryItems ?? []
        if base.scheme == "raycast" {
            let payload = ["code": code]
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
                  let json = String(data: data, encoding: .utf8) else {
                return nil
            }
            items.append(URLQueryItem(name: "context", value: json))
        } else {
            items.append(URLQueryItem(name: "code", value: code))
        }
        components.queryItems = items
        return components.url
    }
}
