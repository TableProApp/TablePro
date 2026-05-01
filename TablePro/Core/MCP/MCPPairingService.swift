//
//  MCPPairingService.swift
//  TablePro
//

import AppKit
import CryptoKit
import Foundation
import os

struct PairingExchangeRecord: Sendable, Equatable {
    let plaintextToken: String
    let challenge: String
    let expiresAt: Date
}

final class PairingExchangeStore: @unchecked Sendable {
    static let exchangeWindow: TimeInterval = 300
    static let maxPendingCodes = 50

    private let lock = NSLock()
    private var pending: [String: PairingExchangeRecord] = [:]

    func insert(code: String, record: PairingExchangeRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        prune(now: Date.now)
        guard pending.count < Self.maxPendingCodes else {
            throw MCPError.forbidden(
                String(localized: "Too many pending pairing codes. Try again later.")
            )
        }
        pending[code] = record
    }

    func consume(code: String, verifier: String, now: Date = .now) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        prune(now: now)

        guard let entry = pending[code] else {
            throw MCPError.notFound("pairing code")
        }

        guard entry.expiresAt > now else {
            pending.removeValue(forKey: code)
            throw MCPError.expired("pairing code")
        }

        let computed = Self.sha256Base64Url(of: verifier)
        guard Self.constantTimeEqual(entry.challenge, computed) else {
            throw MCPError.forbidden("challenge mismatch")
        }

        let token = entry.plaintextToken
        pending.removeValue(forKey: code)
        return token
    }

    func pruneExpired(now: Date = .now) {
        lock.lock()
        defer { lock.unlock() }
        prune(now: now)
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    func contains(code: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pending[code] != nil
    }

    private func prune(now: Date) {
        let stale = pending.filter { $0.value.expiresAt <= now }.keys
        for key in stale {
            pending.removeValue(forKey: key)
        }
    }

    static func sha256Base64Url(of value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        let data = Data(digest)
        return data.base64EncodedString()
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

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCPPairingService")
    private static let pruneInterval: Duration = .seconds(60)

    let store: PairingExchangeStore
    private var pruneTask: Task<Void, Never>?

    init(store: PairingExchangeStore = PairingExchangeStore()) {
        self.store = store
        startPruneLoop()
    }

    func startPairing(_ request: PairingRequest) async throws {
        await MCPServerManager.shared.lazyStart()

        guard let tokenStore = MCPServerManager.shared.tokenStore else {
            Self.logger.error("Token store unavailable after lazyStart")
            throw MCPError.internalError("Token store unavailable")
        }

        let approval = try await AlertHelper.runPairingApproval(request: request)

        let connectionAccess: ConnectionAccess = approval.allowedConnectionIds.map { .limited($0) } ?? .all
        let result = await tokenStore.generate(
            name: request.clientName,
            permissions: approval.grantedPermissions,
            connectionAccess: connectionAccess,
            expiresAt: approval.expiresAt
        )

        let code = UUID().uuidString
        do {
            try store.insert(
                code: code,
                record: PairingExchangeRecord(
                    plaintextToken: result.plaintext,
                    challenge: request.challenge,
                    expiresAt: Date.now.addingTimeInterval(PairingExchangeStore.exchangeWindow)
                )
            )
        } catch {
            await tokenStore.delete(tokenId: result.token.id)
            throw error
        }

        guard let redirect = buildRedirectURL(base: request.redirectURL, code: code) else {
            Self.logger.error("Failed to build pairing redirect URL")
            await tokenStore.delete(tokenId: result.token.id)
            throw MCPError.invalidParams("redirect URL")
        }

        Self.logger.info("Pairing approved for client '\(request.clientName, privacy: .public)'")
        NSWorkspace.shared.open(redirect)
    }

    func exchange(_ exchange: PairingExchange) throws -> String {
        try store.consume(code: exchange.code, verifier: exchange.verifier)
    }

    private func startPruneLoop() {
        pruneTask = Task { [store] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pruneInterval)
                guard !Task.isCancelled else { return }
                store.pruneExpired()
            }
        }
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
