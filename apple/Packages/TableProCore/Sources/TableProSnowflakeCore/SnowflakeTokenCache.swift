import Foundation
import os
import Security

public protocol SnowflakeTokenStorage: Sendable {
    func read(key: String) -> String?
    @discardableResult
    func write(_ value: String, key: String) -> Bool
    func delete(key: String)
}

public final class SnowflakeTokenCache: Sendable {
    private let storage: any SnowflakeTokenStorage
    private let memory = OSAllocatedUnfairLock(initialState: [String: String]())

    public init(storage: any SnowflakeTokenStorage) {
        self.storage = storage
    }

    public func token(for account: SnowflakeAccount, user: String) -> String? {
        let key = account.tokenKey(user: user)
        if let cached = memory.withLock({ $0[key] }) {
            return cached
        }
        if let stored = storage.read(key: key) {
            memory.withLock { $0[key] = stored }
            return stored
        }
        guard let legacyKey = account.legacyTokenKey(user: user), let legacy = storage.read(key: legacyKey) else {
            return nil
        }
        memory.withLock { $0[key] = legacy }
        // The old item stays for 0.83.1, which reads only it; once copied, this build never reads it again.
        storage.write(legacy, key: key)
        return legacy
    }

    public func store(_ token: String, for account: SnowflakeAccount, user: String) {
        let key = account.tokenKey(user: user)
        memory.withLock { $0[key] = token }
        storage.write(token, key: key)
    }

    public func clear(for account: SnowflakeAccount, user: String) {
        let key = account.tokenKey(user: user)
        memory.withLock { $0[key] = nil }
        storage.delete(key: key)
        if let legacyKey = account.legacyTokenKey(user: user) {
            storage.delete(key: legacyKey)
        }
    }
}

public struct SnowflakeKeychainTokenStorage: SnowflakeTokenStorage {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SnowflakeTokenCache")

    public let service: String

    public init(service: String) {
        self.service = service
    }

    public func read(key: String) -> String? {
        var query = baseQuery(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func write(_ value: String, key: String) -> Bool {
        var addQuery = baseQuery(key: key)
        addQuery[kSecValueData as String] = Data(value.utf8)
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(
                baseQuery(key: key) as CFDictionary,
                [kSecValueData as String: Data(value.utf8)] as CFDictionary
            )
        }
        if status != errSecSuccess {
            Self.logger.warning(
                "Could not persist a token in \(service, privacy: .public) (OSStatus \(status)); it is cached in memory only"
            )
        }
        return status == errSecSuccess
    }

    public func delete(key: String) {
        SecItemDelete(baseQuery(key: key) as CFDictionary)
    }

    private func baseQuery(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }
}
