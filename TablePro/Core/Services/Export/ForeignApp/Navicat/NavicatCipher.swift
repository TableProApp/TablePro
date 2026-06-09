//
//  NavicatCipher.swift
//  TablePro
//
//  Fixed-key ciphers a `.ncx` export uses for passwords. Reference:
//  github.com/HyperSine/how-does-navicat-encrypt-password
//  - v2 (Navicat 12+): AES-128-CBC, PKCS#7, key `libcckeylibcckey`, IV `libcciv libcciv `
//  - v1 (Navicat 11): Blowfish-ECB in a custom CBC-style XOR chain, key
//        `SHA1("3DC5CA39")`, IV `BlowfishECB(0xFF * 8)`
//

import CommonCrypto
import Foundation

enum NavicatCipher {
    static func decrypt(_ hex: String) -> String? {
        guard !hex.isEmpty, let ciphertext = Data(navicatHex: hex) else { return nil }
        if let value = decryptV2(ciphertext), isPlausibleText(value) { return value }
        if let value = decryptV1(ciphertext), isPlausibleText(value) { return value }
        return nil
    }

    private static func isPlausibleText(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.unicodeScalars.allSatisfy { $0.properties.generalCategory != .control }
    }

    // MARK: - V2 (Navicat 12+)

    private static let aesKey = Data("libcckeylibcckey".utf8)
    private static let aesIV = Data("libcciv libcciv ".utf8)

    private static func decryptV2(_ ciphertext: Data) -> String? {
        guard !ciphertext.isEmpty, ciphertext.count.isMultiple(of: kCCBlockSizeAES128) else { return nil }

        let bufferSize = ciphertext.count + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var decryptedSize = 0

        let status = buffer.withUnsafeMutableBytes { bufferBytes in
            ciphertext.withUnsafeBytes { cipherBytes in
                aesIV.withUnsafeBytes { ivBytes in
                    aesKey.withUnsafeBytes { keyBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, kCCKeySizeAES128,
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
        return String(data: buffer.prefix(decryptedSize), encoding: .utf8)
    }

    // MARK: - V1 (Navicat 11)

    private static let blowfishKey = sha1(Data("3DC5CA39".utf8))
    private static let blockSize = 8

    private static func decryptV1(_ ciphertext: Data) -> String? {
        guard !ciphertext.isEmpty,
              var vector = blowfishECB([UInt8](repeating: 0xFF, count: blockSize), operation: kCCEncrypt) else {
            return nil
        }

        let bytes = [UInt8](ciphertext)
        let fullBlocks = bytes.count / blockSize
        var output = [UInt8]()
        output.reserveCapacity(bytes.count)

        for blockIndex in 0..<fullBlocks {
            let start = blockIndex * blockSize
            let block = Array(bytes[start..<start + blockSize])
            guard let decrypted = blowfishECB(block, operation: kCCDecrypt) else { return nil }
            for offset in 0..<blockSize {
                output.append(decrypted[offset] ^ vector[offset])
            }
            for offset in 0..<blockSize {
                vector[offset] ^= block[offset]
            }
        }

        let remainder = bytes.count % blockSize
        if remainder > 0 {
            guard let keystream = blowfishECB(vector, operation: kCCEncrypt) else { return nil }
            let tailStart = fullBlocks * blockSize
            for offset in 0..<remainder {
                output.append(bytes[tailStart + offset] ^ keystream[offset])
            }
        }

        return String(bytes: output, encoding: .utf8)
    }

    // MARK: - Primitives

    private static func blowfishECB(_ block: [UInt8], operation: Int) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: block.count)
        var movedBytes = 0
        let status = blowfishKey.withUnsafeBytes { keyBytes in
            CCCrypt(
                CCOperation(operation),
                CCAlgorithm(kCCAlgorithmBlowfish),
                CCOptions(kCCOptionECBMode),
                keyBytes.baseAddress, blowfishKey.count,
                nil,
                block, block.count,
                &output, output.count,
                &movedBytes
            )
        }
        guard status == kCCSuccess, movedBytes == block.count else { return nil }
        return output
    }

    private static func sha1(_ data: Data) -> Data {
        var hash = Data(count: Int(CC_SHA1_DIGEST_LENGTH))
        hash.withUnsafeMutableBytes { hashBytes in
            data.withUnsafeBytes { dataBytes in
                _ = CC_SHA1(dataBytes.baseAddress, CC_LONG(data.count), hashBytes.bindMemory(to: UInt8.self).baseAddress)
            }
        }
        return hash
    }
}

private extension Data {
    init?(navicatHex hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
