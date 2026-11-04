//
//  KdbxDatabase.swift
//  TablePro
//

import CommonCrypto
import Foundation
import os
import TableProGzip

enum KdbxError: Error {
    case malformedHeader
    case unsupportedVersion
    case wrongKey
    case corruptedData
}

struct KdbxEntry {
    let title: String
    let userName: String
    let password: String
}

// The KDBX 3.1 file (`c.kdbx`) JetBrains IDEs write: AES-KDF, an AES-256-CBC body, optionally gzipped XML.
enum KdbxDatabase {
    private static let logger = Logger(subsystem: "com.TablePro", category: "KdbxDatabase")

    private static let sig1: UInt32 = 0x9AA2_D903
    private static let sig2: UInt32 = 0xB54B_FB67

    // Far above what the IDE writes, and a second or two of work at most, so a crafted file cannot
    // hold the import for good.
    static let maximumTransformRounds: UInt64 = 50_000_000
    static let maximumBodyByteCount = ForeignAppFile.maximumByteCount

    private struct Header {
        var mainSeed: [UInt8] = []
        var transformSeed: [UInt8] = []
        var transformRounds: UInt64 = 0
        var encryptionIV: [UInt8] = []
        var protectedStreamKey: [UInt8] = []
        var streamStartBytes: [UInt8] = []
        var innerStreamID: UInt32 = 0
        var compression: UInt32 = 0
    }

    static func read(fileData: Data, mainKey: [UInt8]) throws -> [KdbxEntry] {
        let bytes = [UInt8](fileData)
        let (header, payloadOffset) = try parseHeader(bytes)

        let finalKey = try deriveFinalKey(header: header, mainKey: mainKey)
        let payload = Array(bytes[payloadOffset...])

        guard let plaintext = aesCBCDecrypt(payload, key: finalKey, iv: header.encryptionIV) else {
            throw KdbxError.corruptedData
        }
        guard plaintext.count >= 32, Array(plaintext.prefix(32)) == header.streamStartBytes else {
            throw KdbxError.wrongKey
        }

        guard let deframed = dehashBlocks(Array(plaintext.dropFirst(32))) else {
            throw KdbxError.corruptedData
        }
        let xmlBytes = header.compression == 1 ? (gunzip(deframed) ?? []) : deframed
        guard !xmlBytes.isEmpty else { throw KdbxError.corruptedData }

        let cipher = makeInnerCipher(id: header.innerStreamID, streamKey: header.protectedStreamKey)
        return parseEntries(Data(xmlBytes), cipher: cipher)
    }

    // MARK: - Header

    private static func parseHeader(_ data: [UInt8]) throws -> (Header, Int) {
        guard data.count > 12,
              readUInt32LE(data, 0) == sig1,
              readUInt32LE(data, 4) == sig2,
              let version = readUInt32LE(data, 8) else {
            throw KdbxError.malformedHeader
        }
        guard (version & 0xFFFF_0000) <= 0x0003_0000 else { throw KdbxError.unsupportedVersion }

        var header = Header()
        var pos = 12
        while pos + 3 <= data.count {
            let fieldType = data[pos]
            guard let rawLength = readUInt16LE(data, pos + 1) else { throw KdbxError.malformedHeader }
            let length = Int(rawLength)
            pos += 3
            guard pos + length <= data.count else { throw KdbxError.malformedHeader }
            let field = Array(data[pos..<pos + length])
            pos += length

            switch fieldType {
            case 0: return (header, pos)
            case 3: header.compression = try numeric(readUInt32LE(field, 0))
            case 4: header.mainSeed = field
            case 5: header.transformSeed = field
            case 6: header.transformRounds = try numeric(readUInt64LE(field, 0))
            case 7: header.encryptionIV = field
            case 8: header.protectedStreamKey = field
            case 9: header.streamStartBytes = field
            case 10: header.innerStreamID = try numeric(readUInt32LE(field, 0))
            default: break
            }
        }
        throw KdbxError.malformedHeader
    }

    // A numeric field shorter than its type is malformed, not read past its end.
    private static func numeric<Value>(_ value: Value?) throws -> Value {
        guard let value else { throw KdbxError.malformedHeader }
        return value
    }

    // MARK: - Key Derivation

    private static func deriveFinalKey(header: Header, mainKey: [UInt8]) throws -> [UInt8] {
        guard header.transformRounds <= maximumTransformRounds else { throw KdbxError.malformedHeader }
        let composite = sha256(sha256(mainKey))
        guard let transformed = aesKdf(
            input: composite,
            seed: header.transformSeed,
            rounds: header.transformRounds
        ) else {
            throw KdbxError.corruptedData
        }
        return sha256(header.mainSeed + sha256(transformed))
    }

    private static func aesKdf(input: [UInt8], seed: [UInt8], rounds: UInt64) -> [UInt8]? {
        guard input.count == 32, seed.count == kCCKeySizeAES256 else { return nil }

        var cryptor: CCCryptorRef?
        let createStatus = CCCryptorCreate(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionECBMode),
            seed,
            seed.count,
            nil,
            &cryptor
        )
        guard createStatus == kCCSuccess, let cryptor else { return nil }
        defer { CCCryptorRelease(cryptor) }

        var current = input
        var next = [UInt8](repeating: 0, count: 32)
        for _ in 0..<rounds {
            var moved = 0
            let status = CCCryptorUpdate(cryptor, current, 32, &next, 32, &moved)
            guard status == kCCSuccess, moved == 32 else { return nil }
            swap(&current, &next)
        }
        return current
    }

    // MARK: - Hashed Blocks

    private static func dehashBlocks(_ data: [UInt8]) -> [UInt8]? {
        var result: [UInt8] = []
        var pos = 0
        while pos + 40 <= data.count {
            let hashStart = pos + 4
            guard let rawSize = readUInt32LE(data, pos + 36) else { return nil }
            let size = Int(rawSize)
            pos += 40
            if size == 0 { return result }
            guard pos + size <= data.count else { return nil }
            let block = Array(data[pos..<pos + size])
            guard sha256(block) == Array(data[hashStart..<hashStart + 32]) else { return nil }
            result.append(contentsOf: block)
            pos += size
        }
        return result
    }

    // MARK: - Inner Cipher

    private static func makeInnerCipher(id: UInt32, streamKey: [UInt8]) -> KdbxInnerStreamCipher? {
        switch id {
        case 2:
            return Salsa20Cipher(key: sha256(streamKey), nonce: Salsa20Cipher.keePassNonce)
        case 3:
            let digest = sha512(streamKey)
            return ChaCha20Cipher(key: Array(digest[0..<32]), nonce: Array(digest[32..<44]))
        default:
            logger.warning("Unsupported KDBX inner stream id \(id); passwords will be skipped")
            return nil
        }
    }

    // MARK: - XML

    private static func parseEntries(_ xml: Data, cipher: KdbxInnerStreamCipher?) -> [KdbxEntry] {
        guard let document = try? XMLDocument(data: xml, options: [.nodeLoadExternalEntitiesNever]) else { return [] }

        var decryptedValues: [ObjectIdentifier: String] = [:]
        if var activeCipher = cipher, let valueNodes = try? document.nodes(forXPath: "//Value") {
            for node in valueNodes {
                guard let element = node as? XMLElement,
                      isProtected(element),
                      let encoded = element.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let data = Data(base64Encoded: encoded) else { continue }
                let plain = activeCipher.process([UInt8](data))
                decryptedValues[ObjectIdentifier(element)] = String(bytes: plain, encoding: .utf8) ?? ""
            }
        }

        guard let entryNodes = try? document.nodes(forXPath: "//Entry") else { return [] }
        var entries: [KdbxEntry] = []
        for node in entryNodes {
            guard let entry = node as? XMLElement else { continue }
            entries.append(parseEntry(entry, decryptedValues: decryptedValues))
        }
        return entries
    }

    private static func parseEntry(_ entry: XMLElement, decryptedValues: [ObjectIdentifier: String]) -> KdbxEntry {
        var title = ""
        var userName = ""
        var password = ""
        for stringElement in entry.elements(forName: "String") {
            let key = stringElement.elements(forName: "Key").first?.stringValue ?? ""
            guard let valueElement = stringElement.elements(forName: "Value").first else { continue }
            switch key {
            case "Title": title = valueElement.stringValue ?? ""
            case "UserName": userName = valueElement.stringValue ?? ""
            case "Password":
                if let decrypted = decryptedValues[ObjectIdentifier(valueElement)] {
                    password = decrypted
                } else if !isProtected(valueElement) {
                    password = valueElement.stringValue ?? ""
                } else {
                    // A protected value that did not decrypt is ciphertext, never a password.
                    password = ""
                }
            default: break
            }
        }
        return KdbxEntry(title: title, userName: userName, password: password)
    }

    private static func isProtected(_ value: XMLElement) -> Bool {
        (value.attribute(forName: "Protected")?.stringValue ?? "").lowercased() == "true"
    }

    // MARK: - Crypto Primitives

    private static func aesCBCDecrypt(_ ciphertext: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8]? {
        guard !ciphertext.isEmpty, iv.count == kCCBlockSizeAES128 else { return nil }
        var output = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var outputLength = 0
        let status = CCCrypt(
            CCOperation(kCCDecrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionPKCS7Padding),
            key,
            key.count,
            iv,
            ciphertext,
            ciphertext.count,
            &output,
            output.count,
            &outputLength
        )
        guard status == kCCSuccess else { return nil }
        return Array(output.prefix(outputLength))
    }

    private static func sha256(_ data: [UInt8]) -> [UInt8] {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256(data, CC_LONG(data.count), &hash)
        return hash
    }

    private static func sha512(_ data: [UInt8]) -> [UInt8] {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
        CC_SHA512(data, CC_LONG(data.count), &hash)
        return hash
    }

    // MARK: - GZIP

    private struct BodyTooLarge: Error {}

    private static func gunzip(_ data: [UInt8]) -> [UInt8]? {
        var inflated: [UInt8] = []
        do {
            try GzipInflater.decompress(Data(data)) { chunk in
                guard inflated.count + chunk.count <= maximumBodyByteCount else { throw BodyTooLarge() }
                inflated.append(contentsOf: chunk)
            }
        } catch {
            return nil
        }
        return inflated
    }

    // MARK: - Little-Endian Readers

    private static func readUInt16LE(_ data: [UInt8], _ index: Int) -> UInt16? {
        readLittleEndian(data, index, byteCount: 2).map { UInt16($0) }
    }

    private static func readUInt32LE(_ data: [UInt8], _ index: Int) -> UInt32? {
        readLittleEndian(data, index, byteCount: 4).map { UInt32($0) }
    }

    private static func readUInt64LE(_ data: [UInt8], _ index: Int) -> UInt64? {
        readLittleEndian(data, index, byteCount: 8)
    }

    private static func readLittleEndian(_ data: [UInt8], _ index: Int, byteCount: Int) -> UInt64? {
        guard index >= 0, index + byteCount <= data.count else { return nil }
        var value: UInt64 = 0
        for offset in 0..<byteCount {
            value |= UInt64(data[index + offset]) << (8 * offset)
        }
        return value
    }
}
