//
//  StoredLicenseKey.swift
//  TablePro
//

import CryptoKit
import Foundation

// The license key an older build activated, until the key exchange trades it for an account. The signed payload that
// build kept beside it grants nothing any more: its 30 days' grace ran out once the old license server stopped.
internal struct StoredLicenseKey: @unchecked Sendable {
    static let keychainKey = "com.TablePro.license.key"
    static let payloadKey = "com.TablePro.license.payload"
    // The digest of a key set aside on this Mac, so a different key stored later is not.
    static let setAsideKey = "com.TablePro.license.setAside"

    let keychain: any KeychainStoring
    let defaults: UserDefaults

    func value() -> String? {
        guard case .found(let key) = keychain.readStringResult(forKey: Self.keychainKey) else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // A key the server refused, or whose session was signed out: kept for Use License Key…, never exchanged on its
    // own. The server keeps only its hash, so a deleted key cannot be sent again.
    func setAside() {
        guard let key = value() else { return }
        defaults.set(Self.digest(of: key), forKey: Self.setAsideKey)
    }

    // The digest first, so a Mac with nothing set aside makes no Keychain read.
    func isSetAside() -> Bool {
        guard let digest = defaults.string(forKey: Self.setAsideKey), let key = value() else { return false }
        return digest == Self.digest(of: key)
    }

    // Only once the key was exchanged for its account.
    func clear() {
        keychain.delete(forKey: Self.keychainKey)
        defaults.removeObject(forKey: Self.payloadKey)
        defaults.removeObject(forKey: Self.setAsideKey)
    }

    private static func digest(of key: String) -> String {
        Base64URL.encode(Data(SHA256.hash(data: Data(key.utf8))))
    }
}
