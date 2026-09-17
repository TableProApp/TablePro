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

protocol IntegrityKeySource: Sendable {
    /// The key this device signs its connection store with, or nil when no key can be obtained.
    func key() -> SymmetricKey?
}

struct ConnectionStoreIntegrity: Sendable {
    enum Verdict: Equatable {
        /// The tag matches, so the file is the one TablePro last wrote.
        case trusted
        /// No tag yet. An install that predates this check, or a fresh store.
        case unstamped
        /// A tag exists and does not match. The file changed outside TablePro.
        case modified
        /// No key, so nothing can be said either way. Treated as untrusted rather than assumed
        /// good, for the same reason an unreadable certificate authority fails a connection.
        case unavailable
    }

    static let shared = ConnectionStoreIntegrity()

    private let keySource: any IntegrityKeySource

    init(keySource: any IntegrityKeySource = KeychainIntegrityKeySource()) {
        self.keySource = keySource
    }

    static func tagURL(for fileURL: URL) -> URL {
        fileURL.appendingPathExtension("hmac")
    }

    func verify(_ data: Data, fileURL: URL) -> Verdict {
        guard let key = keySource.key() else { return .unavailable }
        guard let storedTag = try? Data(contentsOf: Self.tagURL(for: fileURL)), !storedTag.isEmpty else {
            return .unstamped
        }

        let expected = Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
        return Self.constantTimeEquals(expected, storedTag) ? .trusted : .modified
    }

    @discardableResult
    func stamp(_ data: Data, fileURL: URL) -> Bool {
        guard let key = keySource.key() else { return false }
        let tag = Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
        do {
            try tag.write(to: Self.tagURL(for: fileURL), options: .atomic)
            return true
        } catch {
            Self.logger.error("Could not write the connection store tag: \(error.localizedDescription)")
            return false
        }
    }

    static func randomKeyBytes(count: Int) -> Data? {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            logger.error("Could not generate a connection store integrity key")
            return nil
        }
        return Data(bytes)
    }

    static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }

    fileprivate static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionStoreIntegrity")
}

/// Holds the key in the keychain under the app's own access control, device local so a tag
/// written on one Mac is never compared against a file on another.
struct KeychainIntegrityKeySource: IntegrityKeySource {
    private static let service = "com.TablePro"
    private static let account = "com.TablePro.connectionStoreIntegrityKey"
    private static let byteCount = 32

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: SymmetricKey?

    func key() -> SymmetricKey? {
        if let isolatedStore = Self.isolatedStore {
            return StoredIntegrityKeySource(store: isolatedStore).key()
        }

        Self.lock.lock()
        defer { Self.lock.unlock() }

        if let cached = Self.cached { return cached }
        if let existing = Self.read() {
            Self.cached = existing
            return existing
        }
        guard let created = Self.create() else { return nil }
        Self.cached = created
        return created
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// A sandboxed run keeps its key inside the sandbox. The production query is left exactly as it
    /// is: the key it finds is the one that stamped the user's existing store, and looking somewhere
    /// else would mint a new key, fail every verification against it, and drop `storeIsTrusted`.
    private static var isolatedStore: (any KeychainStoring)? {
        AppStorageEnvironment.shared.isIsolated ? AppStorageEnvironment.shared.keychain : nil
    }

    private static func read() -> SymmetricKey? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              data.count == byteCount else {
            return nil
        }
        return SymmetricKey(data: data)
    }

    private static func create() -> SymmetricKey? {
        guard let bytes = ConnectionStoreIntegrity.randomKeyBytes(count: byteCount) else { return nil }

        var addQuery = baseQuery()
        addQuery[kSecValueData as String] = bytes
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            ConnectionStoreIntegrity.logger.error(
                "Could not store the connection store integrity key (OSStatus \(status))"
            )
            return nil
        }
        return SymmetricKey(data: bytes)
    }
}

/// Holds the key in a `KeychainStoring` rather than in the system keychain.
///
/// A sandboxed run and a test host both need this: the sandbox keeps its key beside the storage it
/// isolates, and a test host reaches no system keychain item of its own, so `SecItemAdd` fails and
/// every store it writes reads back untrusted.
struct StoredIntegrityKeySource: IntegrityKeySource {
    private static let storageKey = "connectionStoreIntegrity"
    private static let byteCount = 32

    private let store: any KeychainStoring

    init(store: any KeychainStoring) {
        self.store = store
    }

    func key() -> SymmetricKey? {
        if case let .found(encoded) = store.readStringResult(forKey: Self.storageKey),
           let data = Data(base64Encoded: encoded),
           data.count == Self.byteCount {
            return SymmetricKey(data: data)
        }

        guard let bytes = ConnectionStoreIntegrity.randomKeyBytes(count: Self.byteCount) else { return nil }
        guard store.writeString(bytes.base64EncodedString(), forKey: Self.storageKey) else {
            ConnectionStoreIntegrity.logger.error("Could not store the connection store integrity key")
            return nil
        }
        return SymmetricKey(data: bytes)
    }
}
