import CryptoKit
import Foundation
import os
import Security

public enum ConnectionAccess: Sendable, Codable, Equatable {
    case all
    case limited(Set<UUID>)

    var allowedIds: Set<UUID>? {
        switch self {
        case .all: return nil
        case .limited(let ids): return ids
        }
    }

    public func allows(_ connectionId: UUID) -> Bool {
        switch self {
        case .all: return true
        case .limited(let ids): return ids.contains(connectionId)
        }
    }
}

enum MCPTokenStoreError: Error, Sendable, Equatable {
    case randomGenerationFailed(OSStatus)
    case keychainUnavailable(OSStatus)

    var message: String {
        switch self {
        case .randomGenerationFailed(let status):
            return "Secure random generation failed (OSStatus \(status))"
        case .keychainUnavailable(let status):
            return "Keychain unavailable (OSStatus \(status))"
        }
    }
}

struct MCPAuthToken: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let prefix: String
    let tokenHash: String
    let salt: String
    let permissions: TokenPermissions
    let connectionAccess: ConnectionAccess
    let createdAt: Date
    var lastUsedAt: Date?
    let expiresAt: Date?
    var isActive: Bool

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date.now >= expiresAt
    }

    var isEffectivelyActive: Bool { isActive && !isExpired }

    init(
        id: UUID,
        name: String,
        prefix: String,
        tokenHash: String,
        salt: String,
        permissions: TokenPermissions,
        connectionAccess: ConnectionAccess,
        createdAt: Date,
        lastUsedAt: Date?,
        expiresAt: Date?,
        isActive: Bool
    ) {
        self.id = id
        self.name = name
        self.prefix = prefix
        self.tokenHash = tokenHash
        self.salt = salt
        self.permissions = permissions
        self.connectionAccess = connectionAccess
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.expiresAt = expiresAt
        self.isActive = isActive
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case prefix
        case tokenHash
        case salt
        case permissions
        case connectionAccess
        case createdAt
        case lastUsedAt
        case expiresAt
        case isActive
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.prefix = try container.decodeIfPresent(String.self, forKey: .prefix) ?? ""
        self.tokenHash = try container.decode(String.self, forKey: .tokenHash)
        self.salt = try container.decode(String.self, forKey: .salt)
        self.permissions = try container.decode(TokenPermissions.self, forKey: .permissions)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        self.expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        self.isActive = try container.decode(Bool.self, forKey: .isActive)
        self.connectionAccess = try container.decodeIfPresent(ConnectionAccess.self, forKey: .connectionAccess) ?? .all
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(prefix, forKey: .prefix)
        try container.encode(tokenHash, forKey: .tokenHash)
        try container.encode(salt, forKey: .salt)
        try container.encode(permissions, forKey: .permissions)
        try container.encode(connectionAccess, forKey: .connectionAccess)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)
        try container.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try container.encode(isActive, forKey: .isActive)
    }
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

    var scopes: Set<MCPScope> {
        switch self {
        case .readOnly:
            MCPScope.readOnlySet
        case .readWrite:
            MCPScope.readWriteSet
        case .fullAccess:
            MCPScope.fullAccessSet
        }
    }
}

actor MCPTokenStore {
    static let stdioBridgeTokenName = "__stdio_bridge__"
    static let bridgeTokenPermissions: TokenPermissions = .readWrite
    static let defaultTokenLifetime: TimeInterval = 90 * 24 * 60 * 60

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCPTokenStore")

    private var tokens: [MCPAuthToken] = []
    private let credentialStore: any MCPTokenCredentialStoring
    private let legacyStorageUrl: URL
    private var lastSavedAt: ContinuousClock.Instant = .now
    private static let saveCooldown: Duration = .seconds(60)

    private var revocationObservers: [UUID: @Sendable (String) async -> Void] = [:]

    init(credentialStore: any MCPTokenCredentialStoring = MCPTokenKeychainStore()) {
        self.credentialStore = credentialStore
        let directory = AppStorageEnvironment.shared.applicationSupportRoot.appendingPathComponent("TablePro")
        self.legacyStorageUrl = directory.appendingPathComponent("mcp-tokens.json")
    }

    @discardableResult
    func addRevocationObserver(_ handler: @escaping @Sendable (String) async -> Void) -> UUID {
        let id = UUID()
        revocationObservers[id] = handler
        return id
    }

    func removeRevocationObserver(_ id: UUID) {
        revocationObservers.removeValue(forKey: id)
    }

    func generate(
        name: String,
        permissions: TokenPermissions,
        connectionAccess: ConnectionAccess,
        expiresAt: Date?
    ) throws -> (token: MCPAuthToken, plaintext: String) {
        let plaintext = "tp_" + Self.base64UrlEncode(try Self.randomBytes(count: 32))
        let saltBase64 = try Self.randomBytes(count: 16).base64EncodedString()
        let hash = Self.computeHash(salt: saltBase64, plaintext: plaintext)

        let token = MCPAuthToken(
            id: UUID(),
            name: name,
            prefix: String(plaintext.prefix(8)),
            tokenHash: hash,
            salt: saltBase64,
            permissions: permissions,
            connectionAccess: connectionAccess,
            createdAt: Date.now,
            lastUsedAt: nil,
            expiresAt: expiresAt,
            isActive: true
        )

        tokens.append(token)
        save()

        Self.logger.info("Generated MCP token '\(name, privacy: .public)'")
        MCPAuditLogger.logTokenCreated(tokenId: token.id, tokenName: name)
        return (token, plaintext)
    }

    func validate(bearerToken: String) -> MCPAuthToken? {
        for (index, token) in tokens.enumerated() {
            guard token.isActive, !token.isExpired else { continue }

            let candidateHash = Self.computeHash(salt: token.salt, plaintext: bearerToken)
            guard Self.constantTimeCompare(candidateHash, token.tokenHash) else { continue }

            tokens[index].lastUsedAt = Date.now
            saveIfCooldownElapsed()
            return tokens[index]
        }
        return nil
    }

    func revoke(tokenId: UUID) {
        guard let index = tokens.firstIndex(where: { $0.id == tokenId }) else {
            Self.logger.warning("Attempted to revoke non-existent token \(tokenId.uuidString, privacy: .public)")
            return
        }

        tokens[index].isActive = false
        let revokedName = tokens[index].name
        save()
        notifyRevocationObservers(tokenId: tokenId)

        Self.logger.info("Revoked MCP token '\(revokedName, privacy: .public)'")
        MCPAuditLogger.logTokenRevoked(tokenId: tokenId, tokenName: revokedName)
    }

    func delete(tokenId: UUID) {
        guard let index = tokens.firstIndex(where: { $0.id == tokenId }) else {
            Self.logger.warning("Attempted to delete non-existent token \(tokenId.uuidString, privacy: .public)")
            return
        }

        let name = tokens[index].name
        tokens.remove(at: index)
        save()
        notifyRevocationObservers(tokenId: tokenId)

        Self.logger.info("Deleted MCP token '\(name, privacy: .public)'")
    }

    private func notifyRevocationObservers(tokenId: UUID) {
        let observers = Array(revocationObservers.values)
        let key = tokenId.uuidString
        for observer in observers {
            Task { await observer(key) }
        }
    }

    func list() -> [MCPAuthToken] {
        tokens
    }

    func activeTokens() -> [MCPAuthToken] {
        tokens.filter { $0.isActive && !$0.isExpired }
    }

    func token(id: UUID) -> MCPAuthToken? {
        tokens.first { $0.id == id }
    }

    func loadFromDisk() {
        tokens = readCredentialStore() ?? migrateLegacyFileIfPresent()

        let staleCount = tokens.filter { $0.name == Self.stdioBridgeTokenName }.count
        guard staleCount > 0 else { return }
        tokens.removeAll { $0.name == Self.stdioBridgeTokenName }
        save()
        Self.logger.info("Cleaned up \(staleCount) stale bridge token(s)")
    }

    private func readCredentialStore() -> [MCPAuthToken]? {
        guard let data = credentialStore.read() else { return nil }
        do {
            let decoded = try Self.decoder.decode([MCPAuthToken].self, from: data)
            Self.logger.info("Loaded \(decoded.count) MCP tokens from the keychain")
            return decoded
        } catch {
            Self.logger.error("Failed to decode MCP tokens: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func migrateLegacyFileIfPresent() -> [MCPAuthToken] {
        guard FileManager.default.fileExists(atPath: legacyStorageUrl.path) else { return [] }
        defer { try? FileManager.default.removeItem(at: legacyStorageUrl) }

        do {
            let data = try Data(contentsOf: legacyStorageUrl)
            let decoded = try Self.decoder.decode([MCPAuthToken].self, from: data)
            guard let encoded = try? Self.encoder.encode(decoded), credentialStore.write(encoded) else {
                Self.logger.error("Could not migrate MCP tokens into the keychain")
                return decoded
            }
            Self.logger.info("Migrated \(decoded.count) MCP tokens from the legacy file into the keychain")
            return decoded
        } catch {
            Self.logger.error("Failed to read legacy MCP tokens: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func saveIfCooldownElapsed() {
        let now = ContinuousClock.now
        guard now - lastSavedAt > Self.saveCooldown else { return }
        save()
    }

    private func save() {
        lastSavedAt = .now
        do {
            let data = try Self.encoder.encode(tokens)
            guard credentialStore.write(data) else {
                Self.logger.error("Failed to write MCP tokens to the keychain")
                return
            }
        } catch {
            Self.logger.error("Failed to encode MCP tokens: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            logger.error("Secure random generation failed (OSStatus \(status, privacy: .public))")
            throw MCPTokenStoreError.randomGenerationFailed(status)
        }
        return Data(bytes)
    }

    private static func computeHash(salt: String, plaintext: String) -> String {
        let input = salt + plaintext
        guard let data = input.data(using: .utf8) else { return "" }
        return SHA256.hash(data: data).hexEncoded
    }

    private static func base64UrlEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func constantTimeCompare(_ lhs: String, _ rhs: String) -> Bool {
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

protocol MCPTokenCredentialStoring: Sendable {
    func read() -> Data?
    @discardableResult
    func write(_ data: Data) -> Bool
    func delete()
}

struct MCPTokenKeychainStore: MCPTokenCredentialStoring {
    private static let service = "com.TablePro"
    private static let account = "com.TablePro.mcpTokens"
    private static let isolatedKey = "mcpTokens"
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCPTokenKeychainStore")

    private static var isolatedStore: (any KeychainStoring)? {
        AppStorageEnvironment.shared.isIsolated ? AppStorageEnvironment.shared.keychain : nil
    }

    func read() -> Data? {
        if let isolatedStore = Self.isolatedStore {
            guard case .found(let encoded) = isolatedStore.readStringResult(forKey: Self.isolatedKey) else {
                return nil
            }
            return Data(base64Encoded: encoded)
        }

        var query = Self.baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                Self.logger.error("Keychain read failed (OSStatus \(status, privacy: .public))")
            }
            return nil
        }
        return result as? Data
    }

    @discardableResult
    func write(_ data: Data) -> Bool {
        if let isolatedStore = Self.isolatedStore {
            return isolatedStore.writeString(data.base64EncodedString(), forKey: Self.isolatedKey)
        }

        var addQuery = Self.baseQuery()
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        var status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(
                Self.baseQuery() as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
        }
        guard status == errSecSuccess else {
            Self.logger.error("Keychain write failed (OSStatus \(status, privacy: .public))")
            return false
        }
        return true
    }

    func delete() {
        if let isolatedStore = Self.isolatedStore {
            isolatedStore.delete(forKey: Self.isolatedKey)
            return
        }
        let status = SecItemDelete(Self.baseQuery() as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            Self.logger.error("Keychain delete failed (OSStatus \(status, privacy: .public))")
        }
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
    }
}
