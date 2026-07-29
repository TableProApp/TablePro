//
//  BeekeeperEncryptor.swift
//  TablePro
//
//  Re-implements Beekeeper Studio's `simple-encryptor` (Node.js) format so
//  TablePro can read passwords from a Beekeeper `app.db` during import.
//
//  Format produced by `simple-encryptor` with HMAC enabled (Beekeeper's
//  default):
//
//      <hmac-sha256 hex, 64 chars><iv hex, 32 chars><base64(ciphertext)>
//
//  - Encryption key is `SHA-256(rawKeyString)` (32 bytes)
//  - Cipher is AES-256-CBC with PKCS#7 padding
//  - Plaintext is `JSON.stringify(value)` so single string passwords come back
//    wrapped in JSON quotes that must be stripped
//
//  Beekeeper bootstraps its real key with a hardcoded one. The hardcoded
//  default decrypts `~/Library/Application Support/beekeeper-studio/.key`,
//  whose plaintext is `{"encryptionKey":"<64-char hex>"}`. That hex string
//  (passed verbatim, NOT hex-decoded — `simple-encryptor` always SHA-256s the
//  input) is then used to decrypt every password column.
//

import CommonCrypto
import Foundation

enum BeekeeperEncryptor {
    /// Hardcoded bootstrap key from Beekeeper Studio source. Used only to
    /// unwrap the per-install user key from the `.key` file.
    static let defaultKey = "38782F413F442A472D4B6150645367566B59703373367639792442264529482B"

    /// Decrypts a `simple-encryptor` payload with the given raw key string
    /// and returns the JSON-decoded plaintext as a Swift value. Returns nil
    /// if the payload is malformed or decryption fails.
    ///
    /// HMAC verification is intentionally skipped: we read a file the user
    /// owns, and tampered ciphertext will fail the downstream JSON decode
    /// and surface as a nil return anyway. Skipping the HMAC keeps this
    /// helper small and avoids re-implementing `simple-encryptor`'s
    /// constant-time compare.
    static func decrypt(_ payload: String, key: String) -> Any? {
        guard payload.count > 96 else { return nil }
        let ivHexStart = payload.index(payload.startIndex, offsetBy: 64)
        let cipherStart = payload.index(payload.startIndex, offsetBy: 96)
        let ivHex = String(payload[ivHexStart..<cipherStart])
        let cipherBase64 = String(payload[cipherStart...])

        guard let iv = Data(hex: ivHex), iv.count == kCCBlockSizeAES128,
              let cipherData = Data(base64Encoded: cipherBase64) else {
            return nil
        }

        let keyData = sha256(Data(key.utf8))
        guard let plaintext = aes256CBCDecrypt(cipherData, key: keyData, iv: iv) else {
            return nil
        }

        return try? JSONSerialization.jsonObject(
            with: plaintext,
            options: [.fragmentsAllowed]
        )
    }

    /// Typed wrapper for the common single-string case (e.g. a password).
    static func decryptString(_ payload: String, key: String) -> String? {
        decrypt(payload, key: key) as? String
    }

    /// Typed wrapper for the dictionary case (e.g. the `.key` file).
    static func decryptDictionary(_ payload: String, key: String) -> [String: Any]? {
        decrypt(payload, key: key) as? [String: Any]
    }

    // MARK: - Primitives

    private static func sha256(_ data: Data) -> Data {
        var hash = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        hash.withUnsafeMutableBytes { hashBytes in
            data.withUnsafeBytes { dataBytes in
                _ = CC_SHA256(dataBytes.baseAddress, CC_LONG(data.count), hashBytes.bindMemory(to: UInt8.self).baseAddress)
            }
        }
        return hash
    }

    private static func aes256CBCDecrypt(_ ciphertext: Data, key: Data, iv: Data) -> Data? {
        let bufferSize = ciphertext.count + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var decryptedSize = 0

        let status = buffer.withUnsafeMutableBytes { bufferBytes -> CCCryptorStatus in
            ciphertext.withUnsafeBytes { cipherBytes in
                iv.withUnsafeBytes { ivBytes in
                    key.withUnsafeBytes { keyBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, kCCKeySizeAES256,
                            ivBytes.baseAddress,
                            cipherBytes.baseAddress, ciphertext.count,
                            bufferBytes.baseAddress, bufferSize,
                            &decryptedSize
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return buffer.prefix(decryptedSize)
    }
}

private extension Data {
    init?(hex: String) {
        let cleaned = hex.lowercased()
        guard cleaned.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
