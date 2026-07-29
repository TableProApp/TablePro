//
//  BeekeeperEncryptorTests.swift
//  TableProTests
//

import CommonCrypto
import Foundation
import Testing
@testable import TablePro

@Suite("BeekeeperEncryptor")
struct BeekeeperEncryptorTests {
    @Test
    func decryptsStringEncryptedInSimpleEncryptorFormat() throws {
        let key = "user-key-1234567890"
        let plaintext = "hunter2"

        let payload = try encryptForTesting(jsonValue: plaintext, key: key)
        let decoded = BeekeeperEncryptor.decryptString(payload, key: key)

        #expect(decoded == plaintext)
    }

    @Test
    func decryptsDictionaryEncryptedInSimpleEncryptorFormat() throws {
        let key = BeekeeperEncryptor.defaultKey
        let plaintext: [String: String] = ["encryptionKey": "abc123"]

        let payload = try encryptForTesting(jsonValue: plaintext, key: key)
        let decoded = BeekeeperEncryptor.decryptDictionary(payload, key: key)

        #expect(decoded?["encryptionKey"] as? String == "abc123")
    }

    @Test
    func returnsNilForMalformedPayload() {
        #expect(BeekeeperEncryptor.decrypt("too-short", key: "any") == nil)
        #expect(BeekeeperEncryptor.decrypt(String(repeating: "z", count: 200), key: "any") == nil)
    }

    @Test
    func returnsNilForWrongKey() throws {
        let payload = try encryptForTesting(jsonValue: "secret", key: "correct-key")
        #expect(BeekeeperEncryptor.decryptString(payload, key: "wrong-key") == nil)
    }
}

// MARK: - Helper: simple-encryptor wire format

/// Produces a payload matching Node `simple-encryptor` (HMAC enabled). The
/// HMAC is generated but not verified by `BeekeeperEncryptor`, so any 64
/// hex chars at the start would work; we still build a real one to keep the
/// fixture honest.
private func encryptForTesting(jsonValue: Any, key: String) throws -> String {
    let json = try JSONSerialization.data(withJSONObject: jsonValue, options: [.fragmentsAllowed])
    let derivedKey = sha256(Data(key.utf8))
    var iv = Data(count: kCCBlockSizeAES128)
    _ = iv.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, kCCBlockSizeAES128, $0.baseAddress!) }

    let cipher = try aes256CBCEncrypt(json, key: derivedKey, iv: iv)
    let ivHex = iv.map { String(format: "%02x", $0) }.joined()
    let cipherBase64 = cipher.base64EncodedString()
    let hmacInput = (ivHex + cipherBase64).data(using: .utf8) ?? Data()
    let hmacHex = hmacSHA256(hmacInput, key: derivedKey).map { String(format: "%02x", $0) }.joined()
    return hmacHex + ivHex + cipherBase64
}

private func sha256(_ data: Data) -> Data {
    var hash = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
    hash.withUnsafeMutableBytes { hashBytes in
        data.withUnsafeBytes { dataBytes in
            _ = CC_SHA256(dataBytes.baseAddress, CC_LONG(data.count), hashBytes.bindMemory(to: UInt8.self).baseAddress)
        }
    }
    return hash
}

private func hmacSHA256(_ data: Data, key: Data) -> Data {
    var mac = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
    mac.withUnsafeMutableBytes { macBytes in
        key.withUnsafeBytes { keyBytes in
            data.withUnsafeBytes { dataBytes in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA256),
                    keyBytes.baseAddress, key.count,
                    dataBytes.baseAddress, data.count,
                    macBytes.baseAddress
                )
            }
        }
    }
    return mac
}

private func aes256CBCEncrypt(_ plaintext: Data, key: Data, iv: Data) throws -> Data {
    let bufferSize = plaintext.count + kCCBlockSizeAES128
    var buffer = Data(count: bufferSize)
    var written = 0

    let status = buffer.withUnsafeMutableBytes { bufferBytes -> CCCryptorStatus in
        plaintext.withUnsafeBytes { plainBytes in
            iv.withUnsafeBytes { ivBytes in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, kCCKeySizeAES256,
                        ivBytes.baseAddress,
                        plainBytes.baseAddress, plaintext.count,
                        bufferBytes.baseAddress, bufferSize,
                        &written
                    )
                }
            }
        }
    }
    guard status == kCCSuccess else {
        throw NSError(domain: "BeekeeperEncryptorTests", code: Int(status))
    }
    return buffer.prefix(written)
}
