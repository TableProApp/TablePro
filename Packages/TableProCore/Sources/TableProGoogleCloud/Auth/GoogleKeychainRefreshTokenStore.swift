import Foundation
import os
import Security

public struct GoogleKeychainRefreshTokenStore: GoogleRefreshTokenStore {
    public static let service = "com.TablePro.GoogleOAuth"

    private static let logger = Logger(subsystem: "com.TablePro", category: "GoogleKeychainRefreshTokenStore")
    private static let usesDataProtectionKeychain = GoogleKeychainEntitlements.hasApplicationIdentifier

    public init() {}

    public func refreshToken(for clientId: String) -> String? {
        var query = Self.baseQuery(for: clientId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                Self.log(status: status, operation: "read")
            }
            return nil
        }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            return nil
        }
        return token
    }

    public func save(_ refreshToken: String, for clientId: String) {
        let data = Data(refreshToken.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(Self.baseQuery(for: clientId) as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            Self.log(status: updateStatus, operation: "update")
            return
        }
        var addQuery = Self.baseQuery(for: clientId)
        addQuery.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            Self.log(status: addStatus, operation: "add")
        }
    }

    public func removeRefreshToken(for clientId: String) {
        let status = SecItemDelete(Self.baseQuery(for: clientId) as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            Self.log(status: status, operation: "delete")
        }
    }

    private static func baseQuery(for clientId: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: clientId,
            kSecAttrSynchronizable as String: false
        ]
        if usesDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    private static func log(status: OSStatus, operation: String) {
        logger.error("Keychain \(operation, privacy: .public) failed with OSStatus \(status, privacy: .public)")
    }
}

internal enum GoogleKeychainEntitlements {
    static let hasApplicationIdentifier: Bool = {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.application-identifier" as CFString, nil) != nil
        #else
        return true
        #endif
    }()
}
