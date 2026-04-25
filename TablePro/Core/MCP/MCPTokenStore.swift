import CryptoKit
import Foundation
import os
import Security

struct MCPAuthToken: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let prefix: String
    let tokenHash: String
    let salt: String
    let permissions: TokenPermissions
    let allowedConnectionIds: Set<UUID>?
    let createdAt: Date
    var lastUsedAt: Date?
    let expiresAt: Date?
    var isActive: Bool

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date.now >= expiresAt
    }

    var isEffectivelyActive: Bool { isActive && !isExpired }
}

enum TokenPermissions: String, Codable, Sendable, CaseIterable, Identifiable {
    case readOnly
    case readWrite
    case fullAccess

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .readOnly:
            String(localized: "Read Only")
        case .readWrite:
            String(localized: "Read & Write")
        case .fullAccess:
            String(localized: "Full Access")
        }
    }

    func satisfies(_ required: TokenPermissions) -> Bool {
        switch required {
        case .readOnly:
            return true
        case .readWrite:
            return self == .readWrite || self == .fullAccess
        case .fullAccess:
            return self == .fullAccess
        }
    }
}

actor MCPTokenStore {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCPTokenStore")

    private var tokens: [MCPAuthToken] = []
    private let storageUrl: URL
    private var lastSavedAt: ContinuousClock.Instant = .now
    private static let saveCooldown: Duration = .seconds(60)

    init() {
        let appSupportUrl = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let directory = appSupportUrl.appendingPathComponent("com.TablePro")
        self.storageUrl = directory.appendingPathComponent("mcp-tokens.json")
    }

    func generate(
        name: String,
        permissions: TokenPermissions,
        allowedConnectionIds: Set<UUID>? = nil,
        expiresAt: Date? = nil
    ) -> (token: MCPAuthToken, plaintext: String) {
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        let plaintext = "tp_" + base64UrlEncode(keyData)

        var saltBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, saltBytes.count, &saltBytes)
        let saltBase64 = Data(saltBytes).base64EncodedString()

        let hash = computeHash(salt: saltBase64, plaintext: plaintext)
        let tokenPrefix = String(plaintext.prefix(8))

        let token = MCPAuthToken(
            id: UUID(),
            name: name,
            prefix: tokenPrefix,
            tokenHash: hash,
            salt: saltBase64,
            permissions: permissions,
            allowedConnectionIds: allowedConnectionIds,
            createdAt: Date.now,
            lastUsedAt: nil,
            expiresAt: expiresAt,
            isActive: true
        )

        tokens.append(token)
        save()

        Self.logger.info("Generated MCP token '\(name, privacy: .public)' with prefix \(tokenPrefix, privacy: .public)")
        MCPAuditLogger.logTokenCreated(tokenName: name)
        return (token, plaintext)
    }

    func validate(bearerToken: String) -> MCPAuthToken? {
        for (index, token) in tokens.enumerated() {
            guard token.isActive, !token.isExpired else { continue }

            let candidateHash = computeHash(salt: token.salt, plaintext: bearerToken)

            guard constantTimeCompare(candidateHash, token.tokenHash) else { continue }

            tokens[index].lastUsedAt = Date.now
            saveIfCooldownElapsed()

            Self.logger.info("Validated MCP token '\(token.name, privacy: .public)'")
            return tokens[index]
        }

        Self.logger.warning("MCP token validation failed for bearer token")
        return nil
    }

    func revoke(tokenId: UUID) {
        guard let index = tokens.firstIndex(where: { $0.id == tokenId }) else {
            Self.logger.warning("Attempted to revoke non-existent token \(tokenId.uuidString, privacy: .public)")
            return
        }

        tokens[index].isActive = false
        save()

        let revokedName = tokens[index].name
        Self.logger.info("Revoked MCP token '\(revokedName, privacy: .public)'")
        MCPAuditLogger.logTokenRevoked(tokenName: revokedName)
    }

    func delete(tokenId: UUID) {
        guard let index = tokens.firstIndex(where: { $0.id == tokenId }) else {
            Self.logger.warning("Attempted to delete non-existent token \(tokenId.uuidString, privacy: .public)")
            return
        }

        let name = tokens[index].name
        tokens.remove(at: index)
        save()

        Self.logger.info("Deleted MCP token '\(name, privacy: .public)'")
    }

    func list() -> [MCPAuthToken] {
        tokens
    }

    func activeTokens() -> [MCPAuthToken] {
        tokens.filter { $0.isActive && !$0.isExpired }
    }

    func loadFromDisk() {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: storageUrl.path) else {
            Self.logger.info("No existing MCP token file found")
            return
        }

        do {
            let data = try Data(contentsOf: storageUrl)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            tokens = try decoder.decode([MCPAuthToken].self, from: data)
            Self.logger.info("Loaded \(self.tokens.count) MCP tokens from disk")
        } catch {
            Self.logger.error("Failed to load MCP tokens: \(error.localizedDescription, privacy: .public)")
        }

        let staleCount = tokens.filter({ $0.name == "__stdio_bridge__" }).count
        if staleCount > 0 {
            tokens.removeAll { $0.name == "__stdio_bridge__" }
            save()
            Self.logger.info("Cleaned up \(staleCount) stale bridge token(s)")
        }
    }

    private func saveIfCooldownElapsed() {
        let now = ContinuousClock.now
        guard now - lastSavedAt > Self.saveCooldown else { return }
        save()
    }

    private func save() {
        lastSavedAt = .now
        let fileManager = FileManager.default
        let directory = storageUrl.deletingLastPathComponent()

        do {
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try fileManager.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: directory.path
                )
            }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(tokens)

            try data.write(to: storageUrl, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: storageUrl.path
            )
        } catch {
            Self.logger.error("Failed to save MCP tokens: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func computeHash(salt: String, plaintext: String) -> String {
        let input = salt + plaintext
        guard let data = input.data(using: .utf8) else { return "" }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func base64UrlEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func constantTimeCompare(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)

        guard lhsBytes.count == rhsBytes.count else { return false }

        var result: UInt8 = 0
        for i in 0..<lhsBytes.count {
            result |= lhsBytes[i] ^ rhsBytes[i]
        }
        return result == 0
    }
}
