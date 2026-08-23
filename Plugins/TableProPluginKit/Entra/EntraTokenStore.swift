import Foundation
import os
import Security

public struct EntraStoredToken: Codable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date

    public init(accessToken: String, refreshToken: String?, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    public init(_ token: EntraToken) {
        self.init(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expiresAt: token.expiresAt
        )
    }

    public func isFresh(asOf now: Date, margin: TimeInterval = EntraOAuth.refreshMargin) -> Bool {
        expiresAt.timeIntervalSince(now) > margin
    }
}

public protocol EntraTokenStoring: Sendable {
    func load(key: String) -> EntraStoredToken?
    func save(_ token: EntraStoredToken, key: String)
    func clear(key: String)
}

/// Keychain-backed token storage for the Microsoft Entra ID device code flow.
///
/// Items are `AfterFirstUnlockThisDeviceOnly` and never marked synchronizable. A refresh token
/// outlives an access token by up to 90 days, so it stays on the machine that earned it and cannot
/// leave through iCloud Keychain. PluginKit has no keychain wrapper of its own and the app's is
/// internal to the app module, so this talks to Security directly, following SnowflakeIdTokenStore.
public final class EntraKeychainTokenStore: EntraTokenStoring, @unchecked Sendable {
    public static let shared = EntraKeychainTokenStore()

    private let lock = NSLock()
    private var cache: [String: EntraStoredToken] = [:]
    private let service = "com.TablePro.Entra.token"
    private static let logger = Logger(subsystem: "com.TablePro", category: "EntraTokenStore")

    public init() {}

    public func load(key: String) -> EntraStoredToken? {
        if let cached = lock.withLock({ cache[key] }) {
            return cached
        }
        guard let data = readKeychain(key: key),
              let token = try? JSONDecoder().decode(EntraStoredToken.self, from: data)
        else {
            return nil
        }
        lock.withLock { cache[key] = token }
        return token
    }

    public func save(_ token: EntraStoredToken, key: String) {
        lock.withLock { cache[key] = token }
        guard let data = try? JSONEncoder().encode(token) else { return }
        writeKeychain(data, key: key)
    }

    public func clear(key: String) {
        _ = lock.withLock { cache.removeValue(forKey: key) }
        SecItemDelete(baseQuery(key: key) as CFDictionary)
    }

    private func baseQuery(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }

    private func readKeychain(key: String) -> Data? {
        var query = baseQuery(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func writeKeychain(_ data: Data, key: String) {
        var addQuery = baseQuery(key: key)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(
                baseQuery(key: key) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
        }
        if status != errSecSuccess {
            Self.logger.warning(
                "Could not persist the Entra ID token (OSStatus \(status)); it will be cached in memory only"
            )
        }
    }
}

/// Test double. Keeps tokens in memory so the resolver can be exercised without the keychain.
public final class EntraMemoryTokenStore: EntraTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: EntraStoredToken] = [:]

    public init(seed: [String: EntraStoredToken] = [:]) {
        storage = seed
    }

    public func load(key: String) -> EntraStoredToken? {
        lock.withLock { storage[key] }
    }

    public func save(_ token: EntraStoredToken, key: String) {
        lock.withLock { storage[key] = token }
    }

    public func clear(key: String) {
        _ = lock.withLock { storage.removeValue(forKey: key) }
    }
}
