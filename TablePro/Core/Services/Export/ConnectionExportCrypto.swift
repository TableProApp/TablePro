//
//  ConnectionExportCrypto.swift
//  TablePro
//
//  AES-256-GCM encryption for connection export files with PBKDF2 key derivation.
//

import CommonCrypto
import CryptoKit
import Foundation

enum ConnectionExportCryptoError: LocalizedError {
    case invalidPassphrase
    case corruptData
    case unsupportedVersion(UInt8)

    var errorDescription: String? {
        switch self {
        case .invalidPassphrase:
            return String(localized: "Incorrect passphrase")
        case .corruptData:
            return String(localized: "The encrypted file is corrupt or incomplete")
        case .unsupportedVersion(let v):
            return String(localized: "Unsupported encryption version \(v)")
        }
    }
}

enum ConnectionExportCrypto {
    private static let magic = Data("TPRO".utf8) // 4 bytes
    private static let currentVersion: UInt8 = 1
    private static let saltLength = 32
    private static let nonceLength = 12
    private static let pbkdf2Iterations: UInt32 = 600_000
    private static let keyLength = 32 // AES-256

    // Header: magic (4) + version (1) + salt (32) + nonce (12) = 49 bytes
    private static let headerLength = 4 + 1 + saltLength + nonceLength

    static func isEncrypted(_ data: Data) -> Bool {
        data.count > headerLength && data.prefix(4) == magic
    }

    static func encrypt(data: Data, passphrase: String) throws -> Data {
        var salt = Data(count: saltLength)
        let saltStatus = salt.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, saltLength, baseAddress)
        }
        guard saltStatus == errSecSuccess else {
            throw ConnectionExportCryptoError.corruptData
        }

        let key = try deriveKey(passphrase: passphrase, salt: salt)
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(data, using: key, nonce: nonce)

        var result = Data()
        result.append(magic)
        result.append(currentVersion)
        result.append(salt)
        result.append(contentsOf: nonce)
        result.append(sealed.ciphertext)
        result.append(sealed.tag)
        return result
    }

    static func decrypt(data: Data, passphrase: String) throws -> Data {
        guard data.count > headerLength else {
            throw ConnectionExportCryptoError.corruptData
        }
        guard data.prefix(4) == magic else {
            throw ConnectionExportCryptoError.corruptData
        }

        let version = data[4]
        guard version <= currentVersion else {
            throw ConnectionExportCryptoError.unsupportedVersion(version)
        }

        let salt = data[5 ..< 37]
        let nonceData = data[37 ..< 49]
        let ciphertextAndTag = data[49...]

        guard ciphertextAndTag.count > 16 else {
            throw ConnectionExportCryptoError.corruptData
        }

        let ciphertext = ciphertextAndTag.dropLast(16)
        let tag = ciphertextAndTag.suffix(16)

        let key = try deriveKey(passphrase: passphrase, salt: Data(salt))
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)

        do {
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw ConnectionExportCryptoError.invalidPassphrase
        }
    }

    private static func deriveKey(passphrase: String, salt: Data) throws -> SymmetricKey {
        let passphraseData = Data(passphrase.utf8)
        var derivedKey = Data(count: keyLength)

        let status = derivedKey.withUnsafeMutableBytes { derivedKeyBytes in
            passphraseData.withUnsafeBytes { passphraseBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passphraseBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passphraseData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        pbkdf2Iterations,
                        derivedKeyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keyLength
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw ConnectionExportCryptoError.corruptData
        }

        return SymmetricKey(data: derivedKey)
    }
}
