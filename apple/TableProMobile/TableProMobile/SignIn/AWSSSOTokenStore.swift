import Foundation
import os
import Security
import TableProDatabase
import TableProPluginKit

// Keyed by start URL, as the AWS CLI cache is, so every connection on one Identity Center shares a sign-in.
nonisolated struct AWSSSOTokenStore: Sendable {
    static let service = "com.TablePro.AWSSSO.token"

    private static let logger = Logger(subsystem: "com.TablePro", category: "AWSSSOTokenStore")

    private let items: any SecureStore

    init() {
        self.init(items: DeviceOnlyKeychain(service: Self.service))
    }

    init(items: any SecureStore) {
        self.items = items
    }

    static func account(forStartUrl startUrl: String) -> String {
        var normalized = startUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    func token(startUrl: String) -> AWSSSOTokenCacheEntry? {
        let stored: String?
        do {
            stored = try items.retrieve(forKey: Self.account(forStartUrl: startUrl))
        } catch {
            Self.logger.error("Reading the IAM Identity Center token failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let stored, let token = try? JSONDecoder().decode(StoredToken.self, from: Data(stored.utf8)) else {
            return nil
        }
        return token.entry
    }

    func save(_ entry: AWSSSOTokenCacheEntry, startUrl: String) throws {
        let data = try JSONEncoder().encode(StoredToken(entry))
        try items.store(String(decoding: data, as: UTF8.self), forKey: Self.account(forStartUrl: startUrl))
    }

    func clear(startUrl: String) {
        do {
            try items.delete(forKey: Self.account(forStartUrl: startUrl))
        } catch {
            Self.logger.error("Clearing the IAM Identity Center token failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

nonisolated private struct StoredToken: Codable {
    let accessToken: String
    let expiresAt: Date
    let region: String
    let startUrl: String
    let refreshToken: String?
    let clientId: String?
    let clientSecret: String?
    let registrationExpiresAt: Date?

    init(_ entry: AWSSSOTokenCacheEntry) {
        accessToken = entry.accessToken
        expiresAt = entry.expiresAt
        region = entry.region
        startUrl = entry.startUrl
        refreshToken = entry.refreshToken
        clientId = entry.clientId
        clientSecret = entry.clientSecret
        registrationExpiresAt = entry.registrationExpiresAt
    }

    var entry: AWSSSOTokenCacheEntry {
        AWSSSOTokenCacheEntry(
            accessToken: accessToken,
            expiresAt: expiresAt,
            region: region,
            startUrl: startUrl,
            refreshToken: refreshToken,
            clientId: clientId,
            clientSecret: clientSecret,
            registrationExpiresAt: registrationExpiresAt
        )
    }
}

nonisolated private struct DeviceOnlyKeychain: SecureStore {
    let service: String

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    func store(_ value: String, forKey key: String) throws {
        SecItemDelete(baseQuery(key) as CFDictionary)
        var query = baseQuery(key)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.storeFailed(status) }
    }

    func retrieve(forKey key: String) throws -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.retrieveFailed(status) }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(forKey key: String) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.deleteFailed(status) }
    }
}
