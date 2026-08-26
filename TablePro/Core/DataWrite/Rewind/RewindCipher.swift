//
//  RewindCipher.swift
//  TablePro
//
//  Encrypts a rewind record before it touches the disk.
//
//  A rewind record is production row data, and it is the first thing TablePro writes to disk that
//  is. On macOS, NSFileProtection is a volume-level flag rather than a per-file key, so on a Mac
//  without FileVault the file permissions are the only barrier, and the app is not sandboxed. A
//  key in the keychain is what makes the difference between "your rows sit in a readable SQLite
//  file" and not.
//
//  Losing the key loses the history, which is the correct trade: a rewind record is a convenience
//  with a short retention, never a backup.
//

import CryptoKit
import Foundation
import os

struct RewindCipher {
    private static let logger = Logger(subsystem: "com.TablePro", category: "RewindCipher")
    private static let keychainKey = "com.TablePro.rewindStoreKey"

    private let keychain: any KeychainStoring

    init(keychain: any KeychainStoring = KeychainHelper.shared) {
        self.keychain = keychain
    }

    func seal(_ record: RewindRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(record)
        let sealed = try AES.GCM.seal(plaintext, using: try key())
        guard let combined = sealed.combined else {
            throw RewindCipherError.sealFailed
        }
        return combined
    }

    func open(_ data: Data) throws -> RewindRecord {
        let box = try AES.GCM.SealedBox(combined: data)
        let plaintext = try AES.GCM.open(box, using: try key())
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RewindRecord.self, from: plaintext)
    }

    /// Drops the key, which makes every stored record unreadable at once.
    func discardKey() {
        keychain.delete(forKey: Self.keychainKey)
    }

    private func key() throws -> SymmetricKey {
        switch keychain.readStringResult(forKey: Self.keychainKey) {
        case .found(let encoded):
            guard let data = Data(base64Encoded: encoded), data.count == 32 else {
                throw RewindCipherError.keyUnavailable
            }
            return SymmetricKey(data: data)
        case .notFound:
            return try makeKey()
        case .locked, .userCancelled, .authFailed, .error:
            throw RewindCipherError.keyUnavailable
        }
    }

    private func makeKey() throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        let encoded = key.withUnsafeBytes { Data($0) }.base64EncodedString()
        guard keychain.writeString(encoded, forKey: Self.keychainKey) else {
            Self.logger.error("Could not store the rewind key, so no save history will be kept")
            throw RewindCipherError.keyUnavailable
        }
        return key
    }
}

enum RewindCipherError: LocalizedError {
    case keyUnavailable
    case sealFailed

    var errorDescription: String? {
        switch self {
        case .keyUnavailable:
            return String(localized: "The key that protects your save history is not available.")
        case .sealFailed:
            return String(localized: "Could not protect the save history.")
        }
    }
}
