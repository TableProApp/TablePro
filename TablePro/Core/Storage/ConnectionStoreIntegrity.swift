//
//  ConnectionStoreIntegrity.swift
//  TablePro
//
//  connections.json is ordinary user-writable storage, and a connection in it can declare a
//  password source that TablePro executes at connect time. This binds the file to a key only
//  TablePro can read, so a record written by another process is not acted on.
//
//  The tag lives beside the file; forging it needs the key, which the keychain holds under the
//  app's own access control.
//

import CryptoKit
import Foundation
import os
import Security

enum ConnectionStoreIntegrity {
    enum Verdict: Equatable {
        /// The tag matches, so the file is the one TablePro last wrote.
        case trusted
        /// No tag yet. An install that predates this check, or a fresh store.
        case unstamped
        /// A tag exists and does not match. The file changed outside TablePro.
        case modified
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionStoreIntegrity")

    private static let keychainService = "com.TablePro"
    private static let keychainAccount = "com.TablePro.connectionStoreIntegrityKey"
    private static let keyByteCount = 32

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedKey: SymmetricKey?

    static func tagURL(for fileURL: URL) -> URL {
        fileURL.appendingPathExtension("hmac")
    }

    static func verify(_ data: Data, fileURL: URL) -> Verdict {
        guard let key = resolveKey() else { return .unstamped }
        guard let storedTag = try? Data(contentsOf: tagURL(for: fileURL)), !storedTag.isEmpty else {
            return .unstamped
        }

        let expected = Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
        return constantTimeEquals(expected, storedTag) ? .trusted : .modified
    }

    @discardableResult
    static func stamp(_ data: Data, fileURL: URL) -> Bool {
        guard let key = resolveKey() else { return false }
        let tag = Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
        do {
            try tag.write(to: tagURL(for: fileURL), options: .atomic)
            return true
        } catch {
            logger.error("Could not write the connection store tag: \(error.localizedDescription)")
            return false
        }
    }

    static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }

    // MARK: - Key material

    private static func resolveKey() -> SymmetricKey? {
        lock.lock()
        defer { lock.unlock() }

        if let cachedKey { return cachedKey }
        if let existing = readKey() {
            cachedKey = existing
            return existing
        }
        guard let created = createKey() else { return nil }
        cachedKey = created
        return created
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private static func readKey() -> SymmetricKey? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              data.count == keyByteCount else {
            return nil
        }
        return SymmetricKey(data: data)
    }

    private static func createKey() -> SymmetricKey? {
        var bytes = [UInt8](repeating: 0, count: keyByteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            logger.error("Could not generate a connection store integrity key")
            return nil
        }

        var addQuery = baseQuery()
        addQuery[kSecValueData as String] = Data(bytes)
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            logger.error("Could not store the connection store integrity key (OSStatus \(status))")
            return nil
        }
        return SymmetricKey(data: Data(bytes))
    }
}
